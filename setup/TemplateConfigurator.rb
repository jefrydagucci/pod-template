require 'fileutils'
require 'colored2'
require 'xcodeproj'

module Pod
  class TemplateConfigurator

    attr_reader :pod_name, :pods_for_podfile, :prefixes, :test_example_file, :username, :email

    def initialize(pod_name)
      @pod_name = pod_name
      @pods_for_podfile = []
      @prefixes = []
      @message_bank = MessageBank.new(self)
    end

    def ask(question)
      answer = ""
      loop do
        puts "\n#{question}?"

        @message_bank.show_prompt
        answer = gets.chomp

        break if answer.length > 0

        print "\nYou need to provide an answer."
      end
      answer
    end

    def ask_with_answers(question, possible_answers)

      print "\n#{question}? ["

      print_info = Proc.new {

        possible_answers_string = possible_answers.each_with_index do |answer, i|
           _answer = (i == 0) ? answer.underlined : answer
           print " " + _answer
           print(" /") if i != possible_answers.length-1
        end
        print " ]\n"
      }
      print_info.call

      answer = ""

      loop do
        @message_bank.show_prompt
        answer = gets.downcase.chomp

        answer = "yes" if answer == "y"
        answer = "no" if answer == "n"

        # default to first answer
        if answer == ""
          answer = possible_answers[0].downcase
          print answer.yellow
        end

        break if possible_answers.map { |a| a.downcase }.include? answer

        print "\nPossible answers are ["
        print_info.call
      end

      answer
    end

    def run
      @message_bank.welcome_message

      platform = self.ask_with_answers("What platform do you want to use?", ["iOS", "macOS"]).to_sym

      case platform
        when :macos
          ConfigureMacOSSwift.perform(configurator: self)
        when :ios
          framework = self.ask_with_answers("What language do you want to use?", ["Swift", "ObjC"]).to_sym
          case framework
            when :swift
              ConfigureSwift.perform(configurator: self)

            when :objc
              ConfigureIOS.perform(configurator: self)
          end
      end

      replace_variables_in_files
      clean_template_files
      rename_template_files
      add_pods_to_podfile
      customise_prefix
      rename_classes_folder
      ensure_carthage_compatibility
      reinitialize_git_repo
      create_development_pods_project
      run_pod_install

      @message_bank.farewell_message
    end

    #----------------------------------------#

    def ensure_carthage_compatibility
      FileUtils.ln_s('Example/Pods/Pods.xcodeproj', '_Pods.xcodeproj')
    end

    def run_pod_install
      puts "\nRunning " + "pod install".magenta + " on your new library."
      puts ""

      Dir.chdir("Example") do
        system "pod install"
      end

      `git add Example/#{pod_name}.xcodeproj/project.pbxproj`
      `git commit -m "Initial commit"`
    end

    def clean_template_files
      ["./**/.gitkeep", "configure", "_CONFIGURE.rb", "README.md", "LICENSE", "templates", "setup", "CODE_OF_CONDUCT.md"].each do |asset|
        `rm -rf #{asset}`
      end
    end

    def replace_variables_in_files
      file_names = ['POD_LICENSE', 'POD_README.md', 'NAME.podspec', '.travis.yml', podfile_path]
      file_names.each do |file_name|
        text = File.read(file_name)
        text.gsub!("${POD_NAME}", @pod_name)
        text.gsub!("${REPO_NAME}", @pod_name.gsub('+', '-'))
        text.gsub!("${USER_NAME}", user_name)
        text.gsub!("${USER_EMAIL}", user_email)
        text.gsub!("${YEAR}", year)
        text.gsub!("${DATE}", date)
        File.open(file_name, "w") { |file| file.puts text }
      end
    end

    def add_pod_to_podfile podname
      @pods_for_podfile << podname
    end

    def add_pods_to_podfile
      podfile = File.read podfile_path
      podfile_content = @pods_for_podfile.map do |pod|
        "pod '" + pod + "'"
      end.join("\n    ")
      podfile.gsub!("${INCLUDED_PODS}", podfile_content)
      File.open(podfile_path, "w") { |file| file.puts podfile }
    end

    def add_line_to_pch line
      @prefixes << line
    end

    def customise_prefix
      prefix_path = "Example/Tests/Tests-Prefix.pch"
      return unless File.exists? prefix_path

      pch = File.read prefix_path
      pch.gsub!("${INCLUDED_PREFIXES}", @prefixes.join("\n  ") )
      File.open(prefix_path, "w") { |file| file.puts pch }
    end

    def set_test_framework(test_type, extension, folder)
      content_path = "setup/test_examples/" + test_type + "." + extension
      tests_path = "templates/" + folder + "/Example/Tests/Tests." + extension
      tests = File.read tests_path
      tests.gsub!("${TEST_EXAMPLE}", File.read(content_path) )
      File.open(tests_path, "w") { |file| file.puts tests }
    end

    def rename_template_files
      FileUtils.mv "POD_README.md", "README.md"
      FileUtils.mv "POD_LICENSE", "LICENSE"
      FileUtils.mv "NAME.podspec", "#{pod_name}.podspec"
    end

    def rename_classes_folder
      FileUtils.mv "Pod", @pod_name
    end

    def reinitialize_git_repo
      `rm -rf .git`
      `git init`
      `git add -A`
    end

    def validate_user_details
        return (user_email.length > 0) && (user_name.length > 0)
    end

    #----------------------------------------#

    def user_name
      (ENV['GIT_COMMITTER_NAME'] || github_user_name || `git config user.name` || `<GITHUB_USERNAME>` ).strip
    end

    def github_user_name
      github_user_name = `security find-internet-password -s github.com | grep acct | sed 's/"acct"<blob>="//g' | sed 's/"//g'`.strip
      is_valid = github_user_name.empty? or github_user_name.include? '@'
      return is_valid ? nil : github_user_name
    end

    def user_email
      (ENV['GIT_COMMITTER_EMAIL'] || `git config user.email`).strip
    end

    def year
      Time.now.year.to_s
    end

    def date
      Time.now.strftime "%m/%d/%Y"
    end

    def podfile_path
      'Example/Podfile'
    end

    def addfiles(direc, current_group, main_target, changed = false)
        puts "addfiles - `direct`=`#{direc}`, `current_group`=`#{current_group}`, `main_target`=`#{main_target}`"
        Dir.glob(direc) do |item|
          puts "addfiles - `item`=`#{item}`"
            next puts "Next because `.` or `.DS_Store`" if item == '.' or item == '.DS_Store'
            next puts "Next because file (`#{File.basename(item)}`) was in `current_group.children` (#{current_group})" if current_group.children.map { |f| f.name }.include? File.basename(item)
            if File.directory?(item)
                new_folder = File.basename(item)
                created_group = current_group.new_group(new_folder)
                changed = addfiles("#{item}/*", created_group, main_target, changed)
            else
              i = current_group.new_file(item)
              if item.include? ".swift"
                  main_target.add_file_references([i])
                  changed = true
              end
            end
        end
        return changed
    end

    def add_group_to_project(project_path, name_of_generated_folder)
      project = Xcodeproj::Project.open(project_path)

      generated_group = project.main_group[name_of_generated_folder]
      unless generated_group
        generated_group = project.main_group.new_group(name_of_generated_folder)
      end

      main_target = project.targets.first
      added_new_files = addfiles("#{name_of_generated_folder}/*", generated_group, main_target)

      if added_new_files
          project.save
      end
    end

    def create_development_pods_project
      dev_project_configurator = TemplateConfigurator.new("DevelopmentPod")
      dev_project_path = "Example/DevelopmentPods/DevelopmentPod.xcodeproj"

      puts "Installing new xcodeproj..."
      project = Xcodeproj::Project.new(dev_project_path)

      # puts "objects: "
      # puts project.objects
      # puts project.objects.select{ |x|
      #   puts "inside"
      #   puts x.class
      #   puts x
      #   x.class == Xcodeproj::Project::Object::PBXFrameworksBuildPhase
      # }
      # puts Xcodeproj::Project::Object::PBXFrameworksBuildPhase
      # framework_buildphase = project.objects.select{|x| x == Products}
      # framework_buildphase.add_file_reference(libRef)
      project.save()
      puts "Xcodeproj successfully created."

      Pod::ProjectManipulator.new({
        :configurator => dev_project_configurator,
        :xcodeproj_path => dev_project_path,
        :platform => :ios,
        :remove_demo_project => false,
        :prefix => ""
      }).run

      ws_name = "Example/#{pod_name}.xcworkspace"
      project_workspace = Xcodeproj::Workspace.new_from_xcworkspace(ws_name)
      project_workspace.add_group(dev_project_path)
    end

    #----------------------------------------#
  end
end
