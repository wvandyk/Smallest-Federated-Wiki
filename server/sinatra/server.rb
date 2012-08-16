require 'rubygems'
require 'bundler'
require 'pathname'
require 'pp'
Bundler.require

$LOAD_PATH.unshift(File.dirname(__FILE__))
SINATRA_ROOT = File.expand_path(File.dirname(__FILE__))
APP_ROOT = File.expand_path(File.join(SINATRA_ROOT, "..", ".."))

Encoding.default_external = Encoding::UTF_8

require 'server_helpers'
require 'stores/all'
require 'random_id'
require 'page'
require 'favicon'

require 'openid'
require 'openid/store/filesystem'

class Controller < Sinatra::Base
  set :port, 1111
  set :public, File.join(APP_ROOT, "client")
  set :views , File.join(SINATRA_ROOT, "views")
  set :haml, :format => :html5
  set :versions, `git log -10 --oneline` || "no git log"
  if ENV.include?('SESSION_STORE')
    use ENV['SESSION_STORE'].split('::').inject(Object) { |mod, const| mod.const_get(const) }
  else
    enable :sessions
  end
  helpers ServerHelpers

  REMOTE_SITE_JSON_PAGE = %r{^/remote/([a-zA-Z0-9:\.-]+)/([a-z0-9-]+)\.json$}
  REMOTE_SITE_FAVICON = %r{^/remote/([a-zA-Z0-9:\.-]+)/favicon.png$}

  PAGE_NAME = %r{^/([a-z0-9-]+)\.json$}

  HTTP_OK = 200
  HTTP_BAD_REQUEST = 400
  HTTP_UNAUTHORIZED = 401
  HTTP_FORBIDDEN = 403
  HTTP_NOT_FOUND = 404
  HTTP_CONFLICT = 409
  HTTP_NOT_IMPLEMENTED = 501
  TIMESPANS = ['Minute', 'Hour', 'Day', 'Week', 'Month', 'Season', 'Year']

  Store.set ENV['STORE_TYPE'], APP_ROOT

  class << self # overridden in test
    def data_root
      File.join APP_ROOT, "data"
    end
  end

  def farm_page(site=request.host)
    page = Page.new
    page.directory = File.join data_dir(site), "pages"
    page.default_directory = File.join APP_ROOT, "default-data", "pages"
    page.plugins_directory = File.join APP_ROOT, "client", "plugins"
    Store.mkdir page.directory
    page
  end

  def farm_status(site=request.host)
    status = File.join data_dir(site), "status"
    Store.mkdir status
    status
  end

  def data_dir(site)
    Store.farm?(self.class.data_root) ? File.join(self.class.data_root, "farm", site) : self.class.data_root
  end

  def identity
    default_path = File.join APP_ROOT, "default-data", "status", "local-identity"
    real_path = File.join farm_status, "local-identity"
    id_data = Store.get_hash real_path
    id_data ||= Store.put_hash(real_path, FileStore.get_hash(default_path))
  end

  post "/logout" do
    session.delete :authenticated
    redirect "/"
  end

  post '/login' do
    root_url = request.url.match(/(^.*\/{2}[^\/]*)/)[1]
    identifier_file = File.join farm_status, "open_id.identifier"
    identifier = Store.get_text(identifier_file)
    unless identifier
      identifier = params[:identifier]
    end
    open_id_request = openid_consumer.begin(identifier)

    redirect open_id_request.redirect_url(root_url, root_url + "/login/openid/complete")
  end

  get '/login/openid/complete' do
    response = openid_consumer.complete(params, request.url)
    case response.status
      when OpenID::Consumer::FAILURE
        oops HTTP_UNAUTHORIZED, "Login failure"
      when OpenID::Consumer::SETUP_NEEDED
        oops HTTP_BAD_REQUEST, "Setup needed"
      when OpenID::Consumer::CANCEL
        oops HTTP_BAD_REQUEST, "Login cancelled"
      when OpenID::Consumer::SUCCESS
        id = params['openid.identity']
        id_file = File.join farm_status, "open_id.identity"
        stored_id = Store.get_text(id_file)
        if stored_id
          if stored_id == id
            # login successful
            authenticate!
          else
            oops HTTP_FORBIDDEN, "This is not your wiki"
          end
        else
          Store.put_text id_file, id
          # claim successful
          authenticate!
        end
    end
  end

  get '/system/slugs.json' do
    content_type 'application/json'
    cross_origin
    JSON.pretty_generate(Dir.entries(farm_page.directory).reject{|e|e[0] == '.'})
  end

  get '/favicon.png' do
    content_type 'image/png'
    cross_origin
    Favicon.get_or_create(File.join farm_status, 'favicon.png')
  end

  get '/random.png' do
    unless authenticated? or (!identified? and !claimed?)
      halt HTTP_FORBIDDEN
      return
    end

    content_type 'image/png'
    path = File.join farm_status, 'favicon.png'
    Store.put_blob path, Favicon.create_blob
  end

  get '/' do
    haml :view, :locals => {:pages => [ {:id => identity['root']} ]}
  end

  get %r{^/plugins/factory(/factory)?.js$} do
    catalog = Dir.glob(File.join(APP_ROOT, "client/plugins/*/factory.json")).collect do |info|
      begin
        JSON.parse(File.read(info))
      rescue
      end
    end.reject {|info| info.nil?}
    "window.catalog = #{JSON.generate(catalog)};" + File.read(File.join(APP_ROOT, "client/plugins/meta-factory.js"))
  end

  get %r{^/data/([\w -]+)$} do |search|
    content_type 'application/json'
    cross_origin
    pages = Store.annotated_pages farm_page.directory
    candidates = pages.select do |page|
      datasets = page['story'].select do |item|
        item['type']=='data' && item['text'] && item['text'].index(search)
      end
      datasets.length > 0
    end
    halt HTTP_NOT_FOUND unless candidates.length > 0
    JSON.pretty_generate(candidates.first)
  end

  get %r{^/([a-z0-9-]+)\.html$} do |name|
    halt HTTP_NOT_FOUND unless farm_page.exists?(name)
    haml :page, :locals => { :page => farm_page.get(name), :page_name => name }
  end

  get %r{^((/[a-zA-Z0-9:.-]+/[a-z0-9-]+(_rev\d+)?)+)$} do
    elements = params[:captures].first.split('/')
    pages = []
    elements.shift
    while (site = elements.shift) && (id = elements.shift)
      if site == 'view' || site == 'my'
        pages << {:id => id}
      else
        pages << {:id => id, :site => site}
      end
    end
    haml :view, :locals => {:pages => pages}
  end

  get '/system/plugins.json' do
    content_type 'application/json'
    cross_origin
    plugins = []
    path = File.join(APP_ROOT, "client/plugins")
    pathname = Pathname.new path
    Dir.glob("#{path}/*/") {|filename| plugins << Pathname.new(filename).relative_path_from(pathname)}
    JSON.pretty_generate plugins
  end

  get '/system/sitemap.json' do
    content_type 'application/json'
    cross_origin
    pages = Store.annotated_pages farm_page.directory
    sitemap = pages.collect {|p| {"slug" => p['name'], "title" => p['title'], "date" => p['updated_at'].to_i*1000}}
    JSON.pretty_generate sitemap
  end

  get '/recent-changes.json' do
    content_type 'application/json'
    cross_origin
    story = []
    page_bins = pages_by_timespan

    TIMESPANS.each do |timespan|
      next if page_bins[timespan].empty?
      story << recent_change_header(timespan)
      page_bins[timespan].each do |page|
        next if page['story'].empty?
        story << recent_change_story(page)
      end
    end

    page = {'title' => 'Recent Changes', 'story' => story}
    JSON.pretty_generate(page)
  end

  def pages_by_timespan
    pages = Store.annotated_pages farm_page.directory
    page_bins = Hash.new {|hash, key| hash[key] = Array.new}
    pages.each do |page|
      last_updated = Time.now - page['updated_at']
      page_bins[timespan_since(last_updated)] << page
    end
    page_bins
  end

  def recent_change_story(page)
    {'type' => 'federatedWiki', 'site' => site_string, 'slug' => page['name'], 'title' => page['title'], 'text' => "", 'id' => RandomId.generate}
  end

  def recent_change_header(timespan)
    {'type' => 'paragraph', 'text' => "<h3>Within a #{timespan}</h3>", 'id' => RandomId.generate}
  end

  def site_string
    "#{request.host}#{port_string}"
  end

  def port_string
    "#{request.port==80 ? '' : ':'+request.port.to_s}"
  end

  def timespan_since(dt)
    (dt/=60)<1?'Minute':(dt/=60)<1?'Hour':(dt/=24)<1?'Day':(dt/=7)<1?'Week':(dt/=4)<1?'Month':(dt/=3)<1?'Season':(dt/=4)<1?'Year':'Forever'
  end

  get PAGE_NAME do |name|
    content_type 'application/json'
    serve_page name
  end

  error HTTP_FORBIDDEN do
    'Access forbidden'
  end

  put %r{^/page/([a-z0-9-]+)/action$} do |name|
    unless authenticated? or (!identified? and !claimed?)
      halt HTTP_FORBIDDEN
      return
    end

    action = JSON.parse params['action']
    if site = action['fork']
      # this fork is bundled with some other action
      page = JSON.parse RestClient.get("#{site}/#{name}.json")
      ( page['journal'] ||= [] ) << { 'type' => 'fork', 'site' => site }
      farm_page.put name, page
      action.delete 'fork'
    elsif action['type'] == 'create'
      return halt HTTP_CONFLICT if farm_page.exists?(name)
      page = action['item'].clone
    elsif action['type'] == 'fork'
      page = JSON.parse RestClient.get("#{action['site']}/#{name}.json")
    else
      page = farm_page.get(name)
    end

    case action['type']
    when 'move'
      page['story'] = action['order'].collect{ |id| page['story'].detect{ |item| item['id'] == id } }
    when 'add'
      before = action['after'] ? 1+page['story'].index{|item| item['id'] == action['after']} : 0
      page['story'].insert before, action['item']
    when 'remove'
      page['story'].delete_at page['story'].index{ |item| item['id'] == action['id'] }
    when 'edit'
      page['story'][page['story'].index{ |item| item['id'] == action['id'] }] = action['item']
    when 'create', 'fork'
      page['story'] ||= []
    else
      puts "unfamiliar action: #{action.inspect}"
      status HTTP_NOT_IMPLEMENTED
      return "unfamiliar action"
    end
    ( page['journal'] ||= [] ) << action # todo: journal undo, not redo
    farm_page.put name, page
    "ok"
  end

  get REMOTE_SITE_JSON_PAGE do |site, name|
    content_type 'application/json'
    host = site.split(':').first
    if serve_resources_locally?(host)
      serve_page(name, host)
    else
      RestClient.get "#{site}/#{name}.json" do |response, request, result, &block|
        case response.code
        when HTTP_OK
          response
        when HTTP_NOT_FOUND
          halt HTTP_NOT_FOUND
        else
          response.return!(request, result, &block)
        end
      end
    end
  end


  get REMOTE_SITE_FAVICON do |site|
    content_type 'image/png'
    host = site.split(':').first
    if serve_resources_locally?(host)
      Favicon.get_or_create(File.join farm_status(host), 'favicon.png')
    else
      RestClient.get "#{site}/favicon.png"
    end
  end

  not_found do
    oops HTTP_NOT_FOUND, "Page not found"
  end

  put '/submit' do
    content_type 'application/json'
    bundle = JSON.parse params['bundle']
    spawn = "#{(rand*1000000).to_i}.#{request.host}"
    site = request.port == 80 ? spawn : "#{spawn}:#{request.port}"
    bundle.each do |slug, page|
      farm_page(spawn).put slug, page
    end
    citation = {
      "type"=> "federatedWiki",
      "id"=> RandomId.generate,
      "site"=> site,
      "slug"=> "recent-changes",
      "title"=> "Recent Changes",
      "text"=> bundle.collect{|slug, page| "<li> [[#{page['title']||slug}]]"}.join("\n")
    }
    action = {
      "type"=> "add",
      "id"=> citation['id'],
      "date"=> Time.new.to_i*1000,
      "item"=> citation
    }
    slug = 'recent-submissions'
    page = farm_page.get slug
    (page['story']||=[]) << citation
    (page['journal']||=[]) << action
    farm_page.put slug, page
    JSON.pretty_generate citation
  end

end
