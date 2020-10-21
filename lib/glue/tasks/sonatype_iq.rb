require 'glue/tasks/base_task'
require 'json'
require 'glue/util'
require 'pathname'

#Tasks are the things that do the code analysis
# base task knows how to report findings
class Glue::SonatypeIQ < Glue::BaseTask

  # register myself with the base task so it knows to run
  #      3 methods:
  #           run
  #           analyze
  #           supported
  Glue::Tasks.add self
  include Glue::Util

  def initialize(trigger, tracker)
    super(trigger, tracker)
    @name = "SonatypeIQ"
    @description = "OSS Component Analysis with Sonatype Nexus IQ Server"
    #how it knows when to run it
    @stage = :code
    # you can pass a label on the CLI to filter the tools
    @labels << "code" << "oss" << "sca"
    @results = []
  end

  # execute the scanner and save the results in json
  def run
    rootpath = @trigger.path

    #java -jar nexus-iq-cli-latest.jar -i scanIQ -a admin:admin123 -r ./iq-result.json -s http://localhost:8060/iq ./webgoat-7.1.tar 
    #
    #  iq-result.json will be
    #        {
    #           "applicationId" : "scanIQ",
    #          "scanId" : "b05dc29ce7e5477caac514086805ebf1",
    #          "reportHtmlUrl" : "http://localhost:8060/iq/ui/links/application/scanIQ/report/b05dc29ce7e5477caac514086805ebf1",
    #          "reportPdfUrl" : "http://localhost:8060/iq/ui/links/application/scanIQ/report/b05dc29ce7e5477caac514086805ebf1/pdf",
    #          "reportDataUrl" : "http://localhost:8060/iq/api/v2/applications/scanIQ/reports/b05dc29ce7e5477caac514086805ebf1"
    #        }
    @results << runsystem(true, "cat", "/Users/mworthington/Downloads/iq-cli/iq-result.json")
  end

  # read the scan json
  # for each item in the result, map it to how you want to report the finding
  #      call "report" from the base calss to create a new finding
  #          see sfl.rb - a report_finding helper method to parse more complex results
  #      almost like threadfix, but not intending to compete with it
  #
  #  if you're using commercial toosl, you'll need to write your own tasks
  def analyze
    #puts @results
    count = 0

    @results.each do |result|
        begin
          puts "Processing SONATYPE IQ Finding: #{count}"
          count = count + 1

          #puts result

          report_finding! result
        rescue StandardError => e
          log_error(e)
        end
      end
  
    # contrast ingests a report
    # dynamic is the DSL for generic tools

  end

  # how do you know the tool is installed correctly
  def supported?
    #TODO: check to make sure the IQ CLI is set up properly
    return true
  end

  #create a finding
  #    fingerprint - needs to be a unique identifier for a finding
  def report_finding!(result)
    description = "Sonatype IQ Server SECURITY-HIGH Policy Violation"
    detail = "CVE-2019-1234"
    source = "#{@name}:IQServerAppId:scanIQ"
    severity = 1
    fprint = fingerprint("SONATYPEIQ-APPID-COMPONENTID-SVCODE")

    report description, detail, source, severity, fprint
  end

end
