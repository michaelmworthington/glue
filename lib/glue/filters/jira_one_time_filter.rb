require 'glue/filters/base_filter'
require 'jira-ruby'

class Glue::JiraOneTimeFilter < Glue::BaseFilter

  Glue::Filters.add self

  def initialize
    @name = "Jira One Time Filter"
    @description = "Checks that each issue that will be reported doesn't already exist in JIRA."
    @format = :to_jira
  end

  def filter tracker

    if !tracker.options[:output_format].include?(@format)
      return  # Bail in the case where JIRA isn't being used.
    end
    Glue.debug "Have #{tracker.findings.count} items pre JIRA One Time filter."
    options = {
      :username     => tracker.options[:jira_username],
      :password     => tracker.options[:jira_password],
      :site         => tracker.options[:jira_api_url],
      :context_path => tracker.options[:jira_api_context],
      :auth_type    => :basic,
      :http_debug   => tracker.options[:debug],
      :use_ssl => tracker.options[:jira_use_ssl]
      # https://github.com/sumoheavy/jira-ruby/issues/75
    }

    #print "Jira Site: " + options[:site] + "\n"
    #puts "Jira Debug: #{options[:http_debug]}"
    #puts "Jira Use SSL: #{options[:use_ssl]}"
    
    @project = tracker.options[:jira_project]
    @component = tracker.options[:jira_component]
    @jira = JIRA::Client.new(options)

    # print "###################################################################\n"

    #projects = @jira.Project.all
    #projects.each do |project|
    #  print "Project -> key: #{project.key}"
    #end

    # print "###################################################################\n"

    potential_findings = Array.new(tracker.findings)
    tracker.findings.clear
    potential_findings.each do |finding|
    	if confirm_new finding
    		tracker.report finding
    	end
    end
    Glue.debug "Have #{tracker.findings.count} items post JIRA One Time filter."
  end

  private
  def confirm_new finding
    count = 0

    # print "running jira\n"

    # @jira.Issue.jql("project=#{@project}")
    
    @jira.Issue.jql("project=#{@project} AND description ~ '#{finding.fingerprint}' AND resolution is EMPTY").each do |issue|
     count = count + 1  # Must have at least 1 issue with fingerprint.
    end

    # print "###################################################################\n"
    # print "###################################################################\n"

    Glue.debug "Found #{count} items for #{finding.description}"
    if count > 0 then
      # print "apple\n"
      return false
    else
      # print "orange\n"
      return true # New!
    end
  end

end
