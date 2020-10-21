require 'glue/filters/base_filter'
require 'jira-ruby'

class Glue::SonatypeIQJiraAutoCloseFilter < Glue::BaseFilter

  Glue::Filters.add self

  def initialize
    @name = "Sonatype IQ Jira Auto Close Filter"
    @description = "Checks for issues that exist in JIRA that are no longer on the IQ Scan Report and updates their status"
    @format = :to_jira
  end

  def filter tracker

    if !tracker.options[:output_format].include?(@format)
      return  # Bail in the case where JIRA isn't being used.
    end
    Glue.debug "Have #{tracker.findings.count} items pre SONATYPE JIRA One Time filter."
    options = {
      :username     => tracker.options[:jira_username],
      :password     => tracker.options[:jira_password],
      :site         => tracker.options[:jira_api_url],
      :context_path => tracker.options[:jira_api_context],
      :auth_type    => :basic,
      :http_debug   => tracker.options[:debug],
      :use_ssl      => tracker.options[:jira_use_ssl]
    }
    
    @project = tracker.options[:jira_project]
    @component = tracker.options[:jira_component]
    @jira = JIRA::Client.new(options)

    #TODO: I need this to run before the Jira Filter so I know the new scan results vs. what's in Jira
    potential_findings = Array.new(tracker.findings)
    
    #Lookup all jira issues and compare against the current findings
    current_jira_issues = lookup_jira_issues
    current_jira_issues.each do |ticket|
        #puts "#{ticket.id} - #{ticket.key}- #{ticket.summary}"

        if confirm_old ticket
    		  transition_ticket ticket
    	end
    end
    Glue.debug "Have #{tracker.findings.count} items post SONATYPE JIRA One Time filter."
  end

  private
  #TODO: How do we want to lookup the issues for just this project?
  def lookup_jira_issues
    # /rest/api/2/project/DP
    project = @jira.Project.find('DP')
    # /rest/api/2/search?jql=project%3D%22DP%22
    project.issues
  end
  
  def transition_ticket ticket
    transition_id = "21"

    # TODO: How to pick the right transition
    # /rest/api/2/issue/10110/transitions?expand=transitions.fields
    available_transitions = @jira.Transition.all(:issue => ticket)
    available_transitions.each do |ea| 
      #puts "#{ea.name} (id #{ea.id})" 
      if "In Progress" == "#{ea.name}"
        transition_id = ea.id
      end
    end

    Glue.debug "SONATYPE JIRA FILTER: Auto Closing Ticket #{ticket.key} using transition id #{transition_id}"
    transition = ticket.transitions.build
    # /rest/api/2/issue/10110/transitions - [{"transition":{"id":"21"}}]
    transition.save!("transition" => {"id" => transition_id})
  end

  def confirm_old ticket
    #puts "Confirming Ticket: #{ticket.attrs}"

    if "#{ticket.key}" == "DP-34" 
      #puts "SONATYPE JIRA FILTER: ticket DP-34 is old"
      return true
    else
      #puts "SONATYPE JIRA FILTER: Ticket is not old"
      return false
    end

    
    # count = 0
    
    # @jira.Issue.jql("project=#{@project} AND description ~ '#{finding.fingerprint}' AND resolution is EMPTY").each do |issue|
    #  count = count + 1  # Must have at least 1 issue with fingerprint.
    # end

    # Glue.debug "Found #{count} items for #{finding.description}"
    # if count > 0 then
    #   return false
    # else
    #   return true # New!
    # end
  end

end
