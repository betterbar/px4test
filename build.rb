require 'sinatra'
require 'json'
require 'octokit'
require 'open3'
require 'fileutils'

#You can write Visual-Basic in any language!

set :bind, '0.0.0.0'
set :environment, :production
# XXX webrick has issues in recent versions accepting non-localhost transfers
set :server, :thin
set :port, 4567

$ACCESS_TOKEN = ENV['GITTOKEN']
fork = ENV['PX4FORK']

def do_work (command)

  Open3.popen2e(command) do |stdin, stdout_err, wait_thr|

    while line = stdout_err.gets
      puts "OUT> " + line
    end
    exit_status = wait_thr.value
    unless exit_status.success?
      abort "The command #{command} failed!"
    end
  end  
end  

    
def do_clone (srcdir, branch, html_url)
    puts "do_clone: " + branch
    system 'mkdir', '-p', srcdir
    Dir.chdir(srcdir) do
        #git clone <url> --branch <branch> --single-branch [<folder>]
        #result = `git clone --depth 500 #{html_url}.git --branch #{branch} --single-branch `
        #puts result
        do_work "git clone --depth 500 #{html_url}.git --branch #{branch} --single-branch"
        Dir.chdir("Firmware") do
            #result = `git submodule init && git submodule update`
            #puts result
            do_work "git submodule init"
            do_work "git submodule update"
        end
    end
end

def do_master_merge (srcdir, base_repo, base_branch)
    puts "do_merge "
    Dir.chdir(srcdir + "/Firmware") do
        do_work "git remote add base_repo #{base_repo}.git"
        do_work "git fetch base_repo"
        do_work "git merge base_repo/#{base_branch} -m 'Merged #{base_repo}/#{base_branch} into test branch'"
    end
end
    
def do_build (srcdir)
    puts "Starting build"
    Dir.chdir(srcdir+"/Firmware") do
=begin        
        result = `git submodule init`
puts "********************************** git submodule init *******************************************"
        puts result
        result = `git submodule update`
puts "********************************** git submodule update *******************************************"
        puts result
        result = `git submodule status`
puts "********************************** git submodule status *******************************************"
        puts result
        result = `make distclean`
puts "********************************** make distclean *******************************************"
        puts result
        result = `make archives`
puts "********************************** make archives *******************************************"
        puts result
        result = `make -j6 px4fmu-v2_default`
puts "********************************** make -j6 px4fmu-v2_default *******************************************"
        puts result

puts "\n\n**********make upload px4fmu-v2_default aufgerufen************"
        result = `make upload px4fmu-v2_test`
        #result = `Tools/px_uploader.py --port /dev/tty.usbmodem1 Images/px4fmu-v2_default.px4`
puts "********************************** make upload px4fmu-v2_default *******************************************"
        puts result
=end    
        do_work  'BOARDS="px4fmu-v2 px4io-v2" make archives'
        do_work  "make -j8 px4fmu-v2_test"
    end
end    

def set_PR_Status (pr, prstatus)

  if !pr.nil?
    puts "Access token: " + $ACCESS_TOKEN
    client = Octokit::Client.new(:access_token => $ACCESS_TOKEN)
    #puts client.user.location
    #puts pr['base']['repo']['full_name']
    #puts pr['head']['sha']
    client.create_status(pr['base']['repo']['full_name'], pr['head']['sha'], prstatus)
    puts "Set PR status:" + prstatus
  end
end    

def fork_hwtest (pr, srcdir, branch, url)
#Starts the hardware test in a subshell

pid = Process.fork
if pid.nil? then

  lf = '.lockfile'

  # XXX put this into a function and check for a free worker
  # also requires to name directories after the free worker
  while File.file?(lf)
    # Keep waiting as long as the lock file exists
    sleep(1)
  end

  # This is the critical section - we might want to lock it
  # using a 2nd file, or something smarter and proper.
  # XXX for now, we just bet on timing - yay!
  FileUtils.touch(lf)

  # In child
  #exec "pwd"
  do_clone srcdir, branch, url
  if !pr.nil?
    do_master_merge srcdir, pr['base']['repo']['html_url'], pr['base']['ref']
  end
  do_build srcdir
  system 'ruby hwtest.rb'
  puts "HW TEST RESULT:" + $?.exitstatus.to_s

  if ($?.exitstatus == 0) then
    set_PR_Status pr, 'success'
  else
    set_PR_Status pr, 'failed'
  end

  # Clean up by deleting the work directory
  FileUtils.rm_rf(srcdir)

  # We're done - delete lock file
  FileUtils.rm_rf(lf)

#  exec "ruby tstsub.rb"
else
  # In parent
  puts "Worker PID: " + pid.to_s
  Process.detach(pid)
end

end    


# ---------- Routing ------------
get '/' do
  'Hello unknown'
end
get '/payload' do
  "This URL is intended to be used with POST, not GET"
end
post '/payload' do
  body = JSON.parse(request.body.read)
  github_event = request.env['HTTP_X_GITHUB_EVENT']

  case github_event
  when 'ping'
        "Hello"    
  when 'pull_request'
    pr = body["pull_request"]
    number = body['number'];
    if (pr['action'] != 'closed')
      srcdir = pr['head']['sha']
      ENV['srcdir'] = srcdir
      puts "Source directory: #{srcdir}"
      #Set environment vars for sub processes
      ENV['pushername'] = body['sender']['user']
      ENV['pusheremail'] = "lorenz@px4.io"
      branch = pr['head']['ref']
      url = pr['head']['repo']['html_url']
      puts "Pull request: #{number} Cloning branch: " + branch + " from "+ url
      set_PR_Status pr, 'pending'
      fork_hwtest pr, srcdir, branch, url
      'Pull request event queued for testing.'
    else
      puts 'Ignoring closing of pull request #' + String(number)
    end
  when 'push'
    branch = body['ref']

    if !(body['head_commit'].nil?) && body['head_commit'] != 'null'
      srcdir = body['head_commit']['id']
      ENV['srcdir'] = srcdir
      puts "Source directory: #{$srcdir}"
      #Set environment vars for sub processes
      ENV['pushername'] = body ['pusher']['name']
      ENV['pusheremail'] = body ['pusher']['email']
      a = branch.split('/')
      branch = a[a.count-1]           #last part is the bare branchname
      puts "Cloning branch: " + branch + " from "+ body['repository']['html_url']

      fork_hwtest nil, srcdir, branch, body['repository']['html_url']
      'Push event queued for testing.'
    end
  when 'status'
    puts "Ignoring GH status event"
  when 'fork'
    puts 'Ignoring GH fork repo event'
  when 'delete'
    puts 'Ignoring GH delete branch event'

  else
    puts "Unhandled request:"
    puts "Envelope: " + JSON.pretty_generate(request.env)
    puts "JSON: " + JSON.pretty_generate(body)
    puts "Unknown Event: " + github_event

  end
end
