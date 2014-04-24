require 'datetime'
require 'time'
require 'sqlite3'
require 'net/http'
require 'octokit'


uri = URI("http://bioconductor.org/js/versions.js")
@releaseVersion = nil
Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Get.new uri
      response = http.request request
      versions = response.body
      relLine = versions.split("\n").find{|i| i =~ /releaseVersion/}
      @releaseVersion = relLine.split('"')[1].sub(".", "_")
end



@rootdir = "#{ENV['HOME']}/biocsync"
@dbfile = "#{ENV['HOME']}/app/data/gitsvn.sqlite3"
@db = SQLite3::Database.new @dbfile

@github_authorization=
  File.readlines("#{ENV['HOME']}/app/etc/github_authorization.txt").first.strip


Octokit.configure do |c|
    c.access_token = @github_authorization
end

def get_last_known_commit_date(wc_dir, master_branch)
    path = "#{@rootdir}/#{wc_dir}"
    branch = nil
    if (master_branch)
        branch = "master"
    else
        branch = "local-hedgehog"
    end
    Dir.chdir(path) do
        res = `git log #{branch} -n 1` # make sure branch exists!
        lines = res.split("\n")
        dateline = lines.find{|i| i =~ /^Date:/}
        date = dateline.sub /^Date:\s+/, ""
        # example: Sun Apr 20 19:00:53 2014 +0000
        d = DateTime.strptime(date, "%a %b %d %H:%M:%S %Y %z")
        t = Time.parse(d.to_s)
        return(t.utc.iso8601)
    end    
end

def get_github_commits(wc_dir, since_date)
    github_url=
      @db.get_first_row(\
        "select github_url from bridges where local_wc = ?",
      wc_dir).first
    segs = github_url.sub(/\/$/, '').split("/")
    repos = segs.last 
    owner = segs[segs.length-2]

    # FIXME 1. deal with pagination. 
    # FIXME 2. make conditional requests so we don't
    # burn through our rate limit as quickly
    sawyer = Octokit.commits_since("#{owner}/#{repos}", since_date)
    out = []
    for item in sawyer
        out.push item[:commit].to_hash
    end
    h = {}
    h['commits'] = out
    h['repository'] = {}
    h['repository']['url'] = github_url
    h
end



def loop_through_bridges
    rows = @db.execute("select local_wc from bridges;")
    for row in rows
        file = row.first
        if file =~ /^trunk|^branches_RELEASE_#{@releaseVersion}/
            path = "#{@rootdir}/#{file}"
            Dir.chdir(path) do
                branches = ["master", "local-hedgehog"]
                for branch in branches
                    lcd = get_last_known_commit_date(file, (branch=="master"))
                    commits = get_github_commits(file, lcd)
                    unless commits.empty?
                        # do something      
                        puts "#{file} has fallen behind (by #{commits.length}) on #{branch} - #{lcd}"                  
                    end
                end
            end
        end
    end
    nil
end

# FIXME return/log meaningful message
def post_commit(commit_obj)
    return if commit_obj.empty?
    uri = URI.parse("http://gitsvn.bioconductor.org/git-push-hook")
    json = commit_obj.to_json
    response = Net::HTTP.post_form(uri, {"payload" => json})
end