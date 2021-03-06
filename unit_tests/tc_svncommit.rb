ENV['TESTING_GSB'] = 'true'
require "test-unit"
require "test/unit"
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'pry'
require_relative "../app/core"
include GSBCore



Test::Unit.at_start do
    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")
end

Test::Unit.at_exit do
    #FileUtils.rm DB_FILE
end


class TestSvnCommit < Test::Unit::TestCase



    def setup
        FileUtils.rm_f DB_FILE
        db = GSBCore.get_db # force database creation
        GSBCore.login($config['test_username'], $config['test_password'])
        @tmpdir = Dir.mktmpdir
        @svnrepo = "file://#{@tmpdir}/svn-repo"
        @gitrepo = "file://#{@tmpdir}/testrepo.git"
        @ext_svn_wc = "#{@tmpdir}/ext_svn_wc"
        @ext_git_wc = "#{@tmpdir}/ext_git_wc"
        Dir.chdir @tmpdir do
            `svnadmin create svn-repo`
            `svn co #{@svnrepo} ext_svn_wc`
            `git init --bare testrepo.git`
            `git clone #{@gitrepo} ext_git_wc`
        end

    end

    def teardown
        FileUtils.rm_rf @tmpdir
    end

    def cleanup
        # puts "\nin cleanup"
    end


    def setup0
        Dir.chdir @ext_svn_wc do
            f = File.open("foo.txt", "w")
            f.write("i am foo")
            f.close
            `svn add foo.txt`
            `svn commit -m 'adding foo .txt'`
        end

        res = GSBCore.new_bridge(@gitrepo, @svnrepo, "svn-wins",
            $config['test_username'], $config['test_username'],
            $config['test_email'])

        Dir.chdir @ext_svn_wc do
            `svn up` # nothing should happen
            f = File.open("foo.txt", "a")
            f.write("\nadding to foo.txt")
            f.close
            res = `svn commit -m 'added to foo.txt'`
            `svn up`

        end
    end

    def test_get_repos_affected_by_svn_commit
        setup0
        revnum = nil
        Dir.chdir @ext_svn_wc do
            res = `svn up`
            revnum = res.split("At revision ").last.strip.sub(".", "")
        end
        repo = @svnrepo.sub("file://", "")
        res = GSBCore.get_monitored_svn_repos_affected_by_commit(
            revnum, repo)
        assert_equal [@svnrepo], res
    end

    def test_handle_svn_commit_0
        setup0 # reuse
        revnum = nil
        Dir.chdir @ext_svn_wc do
            res = `svn up`
            revnum = res.split("At revision ").last.strip.sub(".", "")
        end
        repo = @svnrepo.sub("file://", "")
        repos = GSBCore.get_monitored_svn_repos_affected_by_commit(
            revnum, repo)
        assert_equal 1, repos.length
        res = GSBCore.handle_svn_commit(repos.first)
        assert_equal "success", res
        Dir.chdir @ext_git_wc do
            `git pull`
            log = `git log -n 1`
            # FIXME why is it indented?
            assert log =~ /added to foo\.txt/
            assert log =~ /SVN Revision number: 2/
            assert log =~ /Consists of 1 commit/
        end

    end


    def setup_test_no_loop
        Dir.chdir @ext_svn_wc do
            f = File.open("foo.txt", "w")
            f.puts "hello, world"
            f.close
            `svn add foo.txt`
            `svn ci -m 'first commit'`
        end

        res = GSBCore.new_bridge(@gitrepo, @svnrepo, "svn-wins",
            $config['test_username'], $config['test_username'],
            $config['test_email'])

        Dir.chdir @ext_git_wc do
            `git pull`
            f = File.open("foo.txt", "a")
            f.puts "added by git"
            f.close
            `git add foo.txt`
            `git commit -m 'added a line'`
            `git push`
        end
    end

    def test_no_loop
        setup_test_no_loop

        mock_push_object = {"repository" => {"url" => @gitrepo}}

        res = GSBCore.handle_git_push(mock_push_object)

        assert_equal "received", res

        revnum = nil
        Dir.chdir @ext_svn_wc do
            res = `svn up`
            revnum = res.split("At revision ").last.strip.sub(".", "")
        end
        repo = @svnrepo.sub("file://", "")
        repos = GSBCore.get_monitored_svn_repos_affected_by_commit(
            revnum, repo)
        assert_equal 1, repos.length
        res = GSBCore.handle_svn_commit(repos.first)

        assert_equal "success", res


    end

    def test_case_handling
        Dir.chdir @ext_svn_wc do
            `touch caseprob caseProb`
            `svn add caseprob caseProb`
            assert_raise do
                GSBCore.svn_commit @ext_svn_wc, "commit message", true
            end
        end
    end

end


