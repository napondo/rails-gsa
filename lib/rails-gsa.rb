require 'http_requestor'
require 'nokogiri'
require 'json'


module RailsGSA

  class NoInternetConnectionError < Exception;
  end

  def self.default_options
    @default_options ||= {:gsa_url => "",
                          :search_term => "",
                          :output => "json",
                          :access => "p",
                          :client => "default_frontend",
                          :proxystylesheet => "default_frontend",
                          :site => "default_collection",
                          :start => 0,
                          :num => 10,
                          :requiredfields => ""
    }
  end

  def self.default_suggest_options
    @default_suggest_options ||= {:gsa_url => "",
                                  :search_term => "",
                                  :max => 10,
                                  :access => "p",
                                  :client => "default_frontend",
                                  :site => "default_collection",
                                  :format => "rich"
    }
  end

  def self.search(args = {})
    default_options
    @default_options.merge!(args)
    raise ArgumentError, "GSA URL missing. Please provide valid arguments." if @default_options[:gsa_url].empty? || @default_options[:gsa_url].nil?

    @default_options[:access] = "p" unless ["p", "s", "a"].include?(@default_options[:access])
    @default_options[:start] = 0 unless @default_options[:start].is_a?(Fixnum)
    @default_options[:num] = 10 unless @default_options[:num].is_a?(Fixnum)

    return perform_search
  end

  def self.suggest(args = {})
    default_suggest_options
    @default_suggest_options.merge!(args)
    raise ArgumentError, "GSA URL missing. Please provide valid arguments." if @default_suggest_options[:gsa_url].empty? || @default_suggest_options[:gsa_url].nil?

    return get_suggestions
  end

  protected
  def self.perform_search
    @http = HTTP::Requestor.new(@default_options[:gsa_url])
    if @default_options[:output] == "json"
      json_response = @http.post(json_search_url).body
      response_object = JSON.parse(json_response)
      return ((response_object.empty? || response_object.nil?) ? {} : response_object)
    elsif @default_options[:output] == "xml"
      return xml_parsed_to_search_results(xml_search_url)
    end
  end

  def self.json_search_url
    url = URI.escape("/cluster"+
                         "?q=#{@default_options[:search_term]}"+
                         "&coutput=json&"+
                         "access=#{@default_options[:access]}&"+
                         "output=xml_no_dtd&"+
                         "client=#{@default_options[:client]}&"+
                         "proxystylesheet=#{@default_options[:proxystylesheet]}&"+
                         "site=#{@default_options[:site]}&"+
                         "start=#{@default_options[:start]}&"+
                         "num=#{@default_options[:num]}&")
    return url + "requiredfields=#{@default_options[:requiredfields]}"
  end

  def self.xml_search_url
    url = URI.escape("/search?q=#{@default_options[:search_term]}&output=xml&client=#{@default_options[:client]}&" +
                         "start=#{@default_options[:start]}&num=#{@default_options[:num]}&filter=0"
    )
    return url
  end

  def self.xml_parsed_to_search_results(url)
    if url.include?("cache")
      new_url = url+"&proxystylesheet=my_frontend"
      return {:cached_page => @http.get(new_url).body}
    else
      new_output = ""
      output = @http.get(url).body
      output.each_line { |line| new_output += line.chop }
      doc = Nokogiri::XML(new_output)
      search_result_nodes = doc.xpath('//GSP/RES')

      all_params = {}
      results = {}
      results[:actual_results] = {}

      doc.xpath('//GSP/PARAM').each do |p|
        case p['name']
          when 'q'
            all_params[:query] = p['value']
          when 'site'
            all_params[:site] = p['value']
          when 'client'
            all_params[:client] = p['value']
          when 'output'
            all_params[:output] = p['value']
          when 'start'
            all_params[:start] = p['value']
        end
      end

      results[:all_params] = all_params
      results[:filtered] = false
      results[:total_results] = 0
      results[:search_time] = doc.xpath('//GSP/TM')[0].text

      unless doc.xpath('//GSP/RES').empty? || doc.xpath('//GSP/RES').nil?
        results[:from] = doc.xpath('//GSP/RES')[0]['SN']
        results[:to] = doc.xpath('//GSP/RES')[0]['EN']
      end

      unless search_result_nodes.empty? || search_result_nodes.nil?
        index = 0
        search_result_nodes.children.each do |child|
          case child.name
            when 'M'
              results[:total_results] = child.text
            when 'NB'
              results[:top_nav] = {}
              child.children.each do |top_nav|
                case top_nav.name
                  when 'PU'
                    results[:top_nav][:previous] = top_nav.text
                  when 'NU'
                    results[:top_nav][:next] = top_nav.text
                end
              end
            when 'R'
              key = "result_#{index}".to_sym
              index+=1
              results[:actual_results][key] = {}
              results[:actual_results][key][:indented] = (child['L'].to_i > 1)
              child.children.each do |ar|
                case ar.name
                  when 'U'
                    results[:actual_results][key][:display_link] = ar.text
                  when 'UE'
                    results[:actual_results][key][:link_for_title] = ar.text
                  when 'T'
                    results[:actual_results][key][:title] = ar.text
                  when 'FS'
                    results[:actual_results][key][:date] = ar['VALUE']
                  when 'S'
                    results[:actual_results][key][:description] = ar.text
                  when 'HAS'
                    ar.children.each do |c|
                      case c.name
                        when 'C'
                          add_to_query = "#{c['CID']}:#{results[:actual_results][key][:link_for_title]}"
                          final_cached_url = "#{@default_options[:gsa_url]}/search?q=cache:#{add_to_query}+#{all_params[:query]}&site=#{all_params[:site]}&client=#{all_params[:client]}&output=#{all_params[:output]}&proxystylesheet=my_frontend"
                          results[:actual_results][key][:cache_link] = final_cached_url
                          results[:actual_results][key][:size] = c['SZ']
                      end
                    end
                  when 'HN'
                    results[:actual_results][key][:more_results] = {}
                    results[:actual_results][key][:more_results][:text] = "More Results from #{ar.text}"
                    sitesearch_url = "/search?q=#{all_params[:query]}&site=#{all_params[:site]}&client=#{all_params[:client]}&output=#{all_params[:output]}&as_sitesearch=#{ar.text}"
                    results[:actual_results][key][:more_results][:link] = "#{root_url.chop}#{sitesearch_url}"
                end
              end
            when 'FI'
              results[:filtered] = true
          end
        end
      end
      return results
    end
  end

  def self.get_suggestions
    @http_sug = HTTP::Requestor.new(@default_suggest_options[:gsa_url])
    if @default_suggest_options[:format] == "rich"
      rich_object = @http_sug.post(suggest_rich_url).body
      return ((rich_object.empty? || rich_object.nil?) ? {} : rich_object)
    elsif @default_suggest_options[:format] == "os"
      os_object = @http_sug.post(suggest_os_url).body
      return ((os_object.empty? || os_object.nil?) ? {} : os_object)
    end
  end

  def self.suggest_rich_url
    url = URI.escape("/suggest"+
                      "?q=#{@default_suggest_options[:search_term]}"+
                      "&max=#{@default_suggest_options[:max]}"+
                      "&site=#{@default_suggest_options[:site]}"+
                      "&client=#{@default_suggest_options[:client]}"+
                      "&access=p"+
                      "&format=rich")
  end

  def self.suggest_os_url
    url = URI.escape("/suggest"+
                     "?q=#{@default_suggest_options[:search_term]}"+
                     "&max=#{@default_suggest_options[:max]}"+
                     "&site=#{@default_suggest_options[:site]}"+
                     "&client=#{@default_suggest_options[:client]}"+
                     "&access=p"+
                     "&format=os")
  end
end