require 'glue/tasks/base_task'
require 'glue/util'
require 'httparty'

class Glue::Contrast < Glue::BaseTask
  Glue::Tasks.add self
  include Glue::Util

  CLOSED_STATUSES = [ 'Remediated', 'Not a Problem' ]
  LIB_RATING_CONNECTOR = 'is currently rated'
  LIB_STALE_CONNECTOR = 'latest version is'

  def initialize(trigger, tracker)
    super(trigger, tracker)
    @name = "Contrast Security"
    @description = "Retrieves findings from Contrast Security"
    @stage = :code
    @labels << "code" << "java" << ".net"


    @api_key = @tracker.options[:contrast_api_key]
    @service_key = @tracker.options[:contrast_service_key]
    @org_id = @tracker.options[:contrast_org_id]
    @app_name = @tracker.options[:contrast_app_name]
    @user_name = @tracker.options[:contrast_user_name]  

    @filter_options = @tracker.options[:contrast_filter_options]
  end

  def run
    Glue.notify "#{@name}"
    
    if @tracker.options[:contrast_update_closed_jira_issues]
      Glue.debug "Updating closed JIRA issues"
      app_id = contrast_app_id(@app_name)
      update_closed_jira_issues(app_id)
    else
      Glue.debug "Running Contrast process"
      app_id = contrast_app_id(@app_name)
      filter_opts = build_filter_options(app_id)
      Glue.debug "Using filter_opts: #{filter_opts}"

      traces = contrast_traces(app_id, filter_opts)
      Glue.debug "Got #{traces.size} traces"

      contrast_vulnerable_libraries(app_id, filter_opts).each do |lib|
        report_vulnerable_lib(app_id, lib) 
      end

      contrast_stale_libraries(app_id, filter_opts).each do |lib|
        report_stale_lib(app_id, lib)
      end

      traces.each do |trace|
        report_trace(app_id, trace)
      end
    end 
  end

  def update_closed_jira_issues(app_id)
    issues = get_closed_jira_issues
    Glue.debug "Found #{issues.size} closed JIRA issues to update"

    issues.each do |iss|
      Glue.debug "Processing issue #{iss.key}"
      contrast_id = contrast_id_for_issue(iss)
      Glue.debug "Got Contrast ID: #{contrast_id}"
      Glue.debug "Using app_id: #{app_id}"

      if !vulnerability?(iss)
        Glue.debug "#{iss.key} is a library issue, skipping."
        next
      end

      trace = contrast_trace_details(app_id, contrast_id)
      Glue.debug "Got trace w/UUID #{trace['uuid']}"

      if !CLOSED_STATUSES.include?(trace['status'])
        Glue.debug "Updating #{trace['uuid']}"
        update_trace(app_id, trace, contrast_resolution_status(iss))
      end
    end
  end

  def vulnerability?(issue)
    !library?(issue)
  end

  def library?(issue)
    issue && issue.description =~ /#{LIB_RATING_CONNECTOR}|#{LIB_STALE_CONNECTOR}/
  end

  def get_closed_jira_issues
    initialize_jira

    @jira.Issue.jql("project=#{@project} AND description ~ 'contrastsecurity*' AND resolution IS NOT EMPTY AND resolutiondate > -3d", 
                      { fields: nil, start_at: nil, max_results: 1000, expand: nil, validate_query: true })
  end

  def initialize_jira
    options = {
      :username     => @tracker.options[:jira_username],
      :password     => @tracker.options[:jira_password],
      :site         => @tracker.options[:jira_api_url],
      :context_path => @tracker.options[:jira_api_context],
      :auth_type    => :basic,
      :http_debug   => tracker.options[:debug],
      :use_ssl => tracker.options[:jira_use_ssl]
    }
    @project = @tracker.options[:jira_project]
    @component = @tracker.options[:jira_component]
    @jira = JIRA::Client.new(options)
  end

  def contrast_id_for_issue(iss)
    return '' if iss.description.blank?

    fingerprints = iss.description.scan(/Fingerprint\:\s*(.*)$/)
    return '' if fingerprints.empty?

    print = fingerprints.first
    return '' if print.blank?

    print = print.first if print.is_a?(Array)

    print.strip
  end

  def contrast_resolution_status(iss)
    return '' if iss.resolution.blank?
    
    res_name = iss.resolution['name']
    return '' if res_name.blank?

    # Possible resolution values (YMMV)
    # ["Fixed", "Won't Fix", "Duplicate", "Incomplete", "Cannot Reproduce", "Done", "Won't Do", "Cancelled", "Complete"]
    case res_name
    when 'Fixed', 'Done', 'Complete', 'Cancelled'
      'Remediated'
    when "Won't Fix", "Won't Do", 'Declined', 'Duplicate'
      'Not a Problem'
    else
      ''
    end
  end

  def report_stale_lib(app_id, lib)
    # report description, detail, source, severity, fingerprint
    self.report "#{lib['file_name']} is out of date.", 
        "Project uses version #{lib['file_version']}, #{LIB_STALE_CONNECTOR} #{lib['latest_version']}. #{contrast_library_html_url(app_id, lib['hash'])}",
        lib['file_name'],
        'NOTE',
        lib['hash']
  end

  def report_vulnerable_lib(app_id, lib)
    vuln_count = lib['total_vulnerabilities']
    self.report "#{lib['file_name']} has #{vuln_count} known security #{vuln_count > 1 ? 'vulnerabilities' : 'vulnerability'}.",
        "#{lib['file_name']} #{LIB_RATING_CONNECTOR} #{lib['grade']}. #{contrast_library_html_url(app_id, lib['hash'])}",
        lib['file_name'],
        'High',
        lib['hash']
  end

  def report_trace(app_id, trace)
    Glue.debug "Reporting trace with fingerprint #{contrast_trace_html_url(app_id, trace['uuid'])}"
    self.report trace['title'], contrast_trace_html_url(app_id, trace['uuid']), trace['uuid'], trace['severity'], trace['uuid']
  end

  def contrast_vulnerable_libraries(app_id, filter_opts)
    contrast_libraries_filtered(app_id, 'VULNERABLE', filter_opts)
  end

  def contrast_stale_libraries(app_id, filter_opts)
    contrast_libraries_filtered(app_id, 'STALE', filter_opts)
  end

  def contrast_libraries_filtered(app_id, filter, filter_opts = { })
    url = "#{contrast_base_url}/applications/#{app_id}/libraries/filter?quickFilter=#{filter}"

    if !filter_opts.empty?
      filter_opts.each do |key, val|
        url << "&#{URI.encode(key)}=#{URI.encode(val)}"
      end
    end

    response = HTTParty.get(url, :headers => contrast_request_headers)
    response['libraries']
  end

  def contrast_app_id(app_name)
    function_url = 'applications/filter?sort=appName'
    url = "#{contrast_base_url}/#{function_url}"
    
    response = HTTParty.get(url, :headers => contrast_request_headers)
    app = response['applications'].detect { |x| x['name'] == app_name }

    app['app_id']
  end

  def build_filter_options(app_id)
    opts = { }

    return opts if @filter_options.nil?

    @filter_options.split(/,/).each do |pair|
      opt, val = pair.split('=')
      opts[opt] = val
    end

    map_indirect_properties!(app_id, opts)
    opts
  end

  def contrast_traces(app_id, filter_opts = { })
    trace_ids = contrast_app_trace_ids(app_id, filter_opts)
    return [ ] if trace_ids.nil?

    res = [ ]
    trace_ids.each do |trace_id|
        res << contrast_trace_details(app_id, trace_id)
    end

    res
  end

  def contrast_server_id_by_name(app_id, server_name)
    res = contrast_server_by_name(app_id, server_name)

    return nil if res.nil?

    res['server_id']
  end

  def contrast_server_by_name(app_id, server_name)
    contrast_servers_by_props(app_id, { 'name' => server_name }).first    
  end

  def map_indirect_properties!(app_id, properties)
    if properties.has_key?('servers')
      server_names = properties['servers']
      server_ids = server_names.split('|').map { |name| contrast_server_id_by_name(app_id, name) }.join(',')
      properties['servers'] = server_ids
    end
  end

  def contrast_servers_by_props(app_id, props)
    res = contrast_servers(app_id)
    props.each do |prop, val|
      res.select! { |server| server[prop] == val }
    end

    res
  end

  def contrast_servers(app_id)
    servers_url = "#{contrast_base_url}/applications/#{app_id}/servers"

    response = HTTParty.get(servers_url, :headers => contrast_request_headers)

    response['servers']
  end

  def contrast_app_trace_ids(app_id, params = { })
    trace_ids_url = "#{contrast_base_url}/traces/#{app_id}/ids"

    args = [ trace_ids_url, { :headers => contrast_request_headers } ]
    
    query = { }
    params.each do |param, val|
      query[param] = val
    end

    args.last[:query] = query unless query.empty?
    response = HTTParty.get(*args)

    response['traces']
  end

  def contrast_trace_details(app_id, trace_id)
    trace_url = "#{contrast_base_url}/traces/#{app_id}/trace/#{trace_id}"
    Glue.debug "contrast_traces trace_url: #{trace_url}"
    Glue.debug "contrast_request_headers: #{contrast_request_headers}"
    response = HTTParty.get(trace_url, :headers => contrast_request_headers)
    Glue.debug "contrast_trace_details response:\n#{response}"

    response['trace']
  end

  def update_trace(app_id, trace, status = 'Remediated')
    payload = {
      'comment_preference' => true,
      'note' => '',
      'status' => status,
      'substatus' => '',
      'traces' => [ trace['uuid'] ]
    }
    
    mark_trace_url = "#{contrast_base_url}/traces/#{app_id}/mark"

    Glue.debug ">>> Updating trace #{trace['uuid']}"
    response = HTTParty.put(mark_trace_url, 
                            :headers => contrast_request_headers,
                            :body => payload.to_json)
  end

  def contrast_trace_html_url(app_id, trace_id)
    "https://app.contrastsecurity.com/Contrast/static/ng/index.html#/#{@org_id}/applications/#{app_id}/vulns/#{trace_id}"
  end

  def contrast_library_html_url(app_id, lib_hash)
    "https://app.contrastsecurity.com/Contrast/static/ng/index.html#/#{@org_id}/applications/#{app_id}/libs/java/#{lib_hash}"
  end

  def contrast_request_headers
    { 'API-Key' => @api_key, 'Authorization' => Base64.urlsafe_encode64("#{@user_name}:#{@service_key}"), 
      'Accept' => 'application/json', 'Content-Type' => 'application/json' }
  end

  def contrast_base_url
    "https://app.contrastsecurity.com/Contrast/api/ng/#{@org_id}"
  end

  def analyze
    # Analysis happens as part of the run method
  end

  def supported?
    true
  end
end
