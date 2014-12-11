# encoding: utf-8
require 'json'
require_relative '../../../models/visualization/member'
require_relative '../../../models/visualization/collection'
require_relative '../../../models/visualization/presenter'
require_relative '../../../models/visualization/locator'
require_relative '../../../models/visualization/copier'
require_relative '../../../models/visualization/name_generator'
require_relative '../../../models/visualization/table_blender'
require_relative '../../../models/visualization/watcher'
require_relative '../../../models/map/presenter'
require_relative '../../../../services/named-maps-api-wrapper/lib/named-maps-wrapper/exceptions'

class Api::Json::VisualizationsController < Api::ApplicationController
  include CartoDB
  
  ssl_allowed  :vizjson1, :vizjson2, :notify_watching, :list_watching
  ssl_required :index, :show, :create, :update, :destroy, :set_next_id
  skip_before_filter :api_authorization_required, only: [:vizjson1, :vizjson2]
  before_filter :link_ghost_tables, only: [:index, :show]
  before_filter :table_and_schema_from_params, only: [:show, :update, :destroy, :stats, :vizjson1, :vizjson2, :notify_watching, :list_watching, :set_next_id]

  def index
    collection = Visualization::Collection.new.fetch(
                   params.dup.merge(scope_for(current_user))
                 )
    table_data = collection.map { |vis|
      if vis.table.nil?
        nil
      else
        {
          name:   vis.table.name,
          schema: vis.user.database_schema
        }
      end
    }.compact
    synchronizations = synchronizations_by_table_name(table_data)
    rows_and_sizes   = rows_and_sizes_for(table_data)

    representation  = collection.map { |vis|
      begin
        vis.to_hash(
          related:    false,
          table_data: !(params[:table_data] =~ /false/),
          user:       current_user,
          table:      vis.table,
          synchronization: synchronizations[vis.name],
          rows_and_sizes: rows_and_sizes
        )
      rescue => exception
        puts exception.to_s + exception.backtrace.join("\n")
      end
    }.compact

    response        = {
      visualizations: representation,
      total_entries:  collection.total_entries
    }
    current_user.update_visualization_metrics
    render_jsonp(response)
  end

  def create
    vis_data = payload

    vis_data.delete(:permission) if vis_data[:permission].present?
    vis_data.delete[:permission_id] if vis_data[:permission_id].present?

    # Don't allow to modify next_id/prev_id, force to use set_next_id()
    prev_id = vis_data.delete(:prev_id) || vis_data.delete('prev_id')
    next_id = vis_data.delete(:next_id) || vis_data.delete('next_id')

    if params[:source_visualization_id]
      source = Visualization::Collection.new.fetch(
        id: params.fetch(:source_visualization_id),
        user_id: current_user.id,
        exclude_raster: true
      ).first
      return(head 403) if source.nil?

      copy_overlays = params.fetch(:copy_overlays, true)
      copy_layers = params.fetch(:copy_layers, true)

      additional_fields = {
        type:       params.fetch(:type, Visualization::Member::TYPE_DERIVED),
        parent_id:  params.fetch(:parent_id, nil)
      }

      vis = Visualization::Copier.new(
        current_user, source, name_candidate
      ).copy(copy_overlays, copy_layers, additional_fields)

    elsif params[:tables]
      viewed_user = User.find(:username => CartoDB.extract_subdomain(request))
      tables = params[:tables].map { |table_name|
        if viewed_user
          ::Table.get_by_id_or_name(table_name,  viewed_user)
        end
      }.flatten
      blender = Visualization::TableBlender.new(current_user, tables)
      map = blender.blend
      vis = Visualization::Member.new(
        vis_data.merge(
          name:     name_candidate,
          map_id:   map.id,
          type:     'derived',
          privacy:  blender.blended_privacy,
          user_id:  current_user.id
        )
      )

      # create default overlays
      Visualization::Overlays.new(vis).create_default_overlays
    else
      vis = Visualization::Member.new(
        add_default_privacy(vis_data).merge(
          name: name_candidate,
          user_id:  current_user.id
        )
      )
    end

    vis.privacy = vis.default_privacy(current_user)

    vis.store
    if !prev_id.nil?
      prev_vis = Visualization::Member.new(id: prev_id).fetch
      return head(403) unless prev_vis.has_permission?(current_user, Visualization::Member::PERMISSION_READWRITE)

      prev_vis.set_next_list_item!(vis)
    elsif !next_id.nil?
      next_vis = Visualization::Member.new(id: next_id).fetch
      return head(403) unless next_vis.has_permission?(current_user, Visualization::Member::PERMISSION_READWRITE)

      next_vis.set_prev_list_item!(vis)
    end

    current_user.update_visualization_metrics
    render_jsonp(vis)
  rescue CartoDB::InvalidMember
    render_jsonp({ errors: vis.full_errors }, 400)
  rescue CartoDB::NamedMapsWrapper::HTTPResponseError => exception
    render_jsonp({ errors: { named_maps_api: "Communication error with tiler API. HTTP Code: #{exception.message}" } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapDataError => exception
    render_jsonp({ errors: { named_map: exception } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapsDataError => exception
    render_jsonp({ errors: { named_maps: exception } }, 400)
  end

  def show
    vis = Visualization::Member.new(id: @table_id).fetch
    return(head 403) unless vis.has_permission?(current_user, Visualization::Member::PERMISSION_READONLY)
    render_jsonp(vis)
  rescue KeyError
    head(404)
  end
  
  def update
    vis = Visualization::Member.new(id: @table_id).fetch
    return head(403) unless vis.has_permission?(current_user, Visualization::Member::PERMISSION_READWRITE)

    vis_data = payload

    vis_data.delete(:permission) || vis_data.delete('permission')
    vis_data.delete(:permission_id)  || vis_data.delete('permission_id')

    # Don't allow to modify next_id/prev_id, force to use set_next_id()
    vis_data.delete(:prev_id) || vis_data.delete('prev_id')
    vis_data.delete(:next_id) || vis_data.delete('next_id')

    # when a table gets renamed, first it's canonical visualization is renamed, so we must revert renaming if that failed
    # This is far from perfect, but works without messing with table-vis sync and their two backends
    if vis.table?
      old_vis_name = vis.name

      vis_data.delete(:url_options) if vis_data[:url_options].present?
      vis.attributes = vis_data
      new_vis_name = vis.name
      old_table_name = vis.table.name
      vis.store.fetch
      if new_vis_name != old_vis_name && vis.table.name == old_table_name
        vis.name = old_vis_name
        vis.store.fetch
      end
    else
      vis.attributes = vis_data
      vis.store.fetch
    end

    render_jsonp(vis)
  rescue KeyError
    head(404)
  rescue CartoDB::InvalidMember
    render_jsonp({ errors: vis.full_errors.empty? ? ['Error saving data'] : vis.full_errors }, 400)
  rescue CartoDB::NamedMapsWrapper::HTTPResponseError => exception
    render_jsonp({ errors: { named_maps_api: "Communication error with tiler API. HTTP Code: #{exception.message}" } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapDataError => exception
    render_jsonp({ errors: { named_map: exception } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapsDataError => exception
    render_jsonp({ errors: { named_maps: exception } }, 400)
  rescue
    render_jsonp({ errors: ['Unknown error'] }, 400)
  end

  def destroy
    vis = Visualization::Member.new(id: @table_id).fetch
    return(head 403) unless vis.is_owner?(current_user)
    vis.delete
    current_user.update_visualization_metrics
    return head 204
  rescue KeyError
    head(404)
  rescue CartoDB::NamedMapsWrapper::HTTPResponseError => exception
    render_jsonp({ errors: { named_maps_api: "Communication error with tiler API. HTTP Code: #{exception.message}" } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapDataError => exception
    render_jsonp({ errors: { named_map: exception } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapsDataError => exception
    render_jsonp({ errors: { named_maps: exception } }, 400)
  end

  def stats
    vis = Visualization::Member.new(id: @table_id).fetch
    return(head 401) unless vis.has_permission?(current_user, Visualization::Member::PERMISSION_READONLY)
    render_jsonp(vis.stats)
  rescue KeyError
    head(404)
  end

  def vizjson1
    visualization,  = locator.get(@table_id, CartoDB.extract_subdomain(request))
    return(head 404) unless visualization
    return(head 403) unless allow_vizjson_v1_for?(visualization.table)
    set_vizjson_response_headers_for(visualization)
    render_jsonp(CartoDB::Map::Presenter.new(
      visualization.map, 
      { full: false, url: "/api/v1/tables/#{visualization.table.id}" },
      Cartodb.config, 
      CartoDB::Logger
    ).to_poro)
  rescue => exception
    CartoDB.notify_exception(exception)
    raise exception
  end

  def vizjson2
    visualization,  = locator.get(@table_id, CartoDB.extract_subdomain(request))
    return(head 404) unless visualization
    return(head 403) unless allow_vizjson_v2_for?(visualization)
    set_vizjson_response_headers_for(visualization)
    render_jsonp(visualization.to_vizjson)
  rescue KeyError => exception
    render(text: exception.message, status: 403)
  rescue CartoDB::NamedMapsWrapper::HTTPResponseError => exception
    CartoDB.notify_exception(exception)
    render_jsonp({ errors: { named_maps_api: "Communication error with tiler API. HTTP Code: #{exception.message}" } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapDataError => exception
    CartoDB.notify_exception(exception)
    render_jsonp({ errors: { named_map: exception.message } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapsDataError => exception
    CartoDB.notify_exception(exception)
    render_jsonp({ errors: { named_maps: exception.message } }, 400)
  rescue => exception
    CartoDB.notify_exception(exception)
    raise exception
  end

  def notify_watching
    vis = Visualization::Member.new(id: @table_id).fetch
    return(head 403) unless vis.has_permission?(current_user, Visualization::Member::PERMISSION_READONLY)
    watcher = CartoDB::Visualization::Watcher.new(current_user, vis)
    watcher.notify
    render_jsonp(watcher.list)
  end

  def list_watching
    vis = Visualization::Member.new(id: @table_id).fetch
    return(head 403) unless vis.has_permission?(current_user, Visualization::Member::PERMISSION_READONLY)
    watcher = CartoDB::Visualization::Watcher.new(current_user, vis)
    render_jsonp(watcher.list)
  end

  def set_next_id
    next_id = payload[:next_id] || payload['next_id']

    prev_vis = Visualization::Member.new(id: @table_id).fetch
    return(head 403) unless prev_vis.has_permission?(current_user, Visualization::Member::PERMISSION_READWRITE)

    if next_id.nil?
      last_children = prev_vis.parent.children.last
      last_children.set_next_list_item!(prev_vis)

      render_jsonp(last_children.to_vizjson)
    else
      next_vis = Visualization::Member.new(id: next_id).fetch
      return(head 403) unless next_vis.has_permission?(current_user, Visualization::Member::PERMISSION_READWRITE)

      prev_vis.set_next_list_item!(next_vis)

      render_jsonp(prev_vis.to_vizjson)
    end
  rescue KeyError
    head(404)
  rescue CartoDB::InvalidMember
    render_jsonp({ errors: ['Error saving next slide position'] }, 400)
  rescue CartoDB::NamedMapsWrapper::HTTPResponseError => exception
    render_jsonp({ errors: { named_maps_api: "Communication error with tiler API. HTTP Code: #{exception.message}" } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapDataError => exception
    render_jsonp({ errors: { named_map: exception } }, 400)
  rescue CartoDB::NamedMapsWrapper::NamedMapsDataError => exception
    render_jsonp({ errors: { named_maps: exception } }, 400)
  rescue
    render_jsonp({ errors: ['Unknown error'] }, 400)
  end

  private

  def table_and_schema_from_params
    if params.fetch('id', nil) =~ /\./
      @table_id, @schema = params.fetch('id').split('.').reverse
    else
      @table_id, @schema = [params.fetch('id', nil), nil]
    end
  end

  def locator
    CartoDB::Visualization::Locator.new
  end

  def scope_for(current_user)
    { user_id: current_user.id }
  end

  def allow_vizjson_v1_for?(table)
    table && (table.public? || table.public_with_link_only? || current_user_is_owner?(table))
  end #allow_vizjson_v1_for?

  def allow_vizjson_v2_for?(visualization)
    visualization && (visualization.public? || visualization.public_with_link?)
  end

  def current_user_is_owner?(table)
    current_user.present? && (table.owner.id == current_user.id)
  end

  def set_vizjson_response_headers_for(visualization)
    response.headers['X-Cache-Channel'] = "#{visualization.varnish_key}:vizjson"
    response.headers['Cache-Control']   = 'no-cache,max-age=86400,must-revalidate, public'
  end

  def payload
    request.body.rewind
    ::JSON.parse(request.body.read.to_s || String.new)
  end

  def add_default_privacy(data)
    { privacy: default_privacy }.merge(data)
  end

  def default_privacy
    current_user.private_tables_enabled ? Visualization::Member::PRIVACY_PRIVATE : Visualization::Member::PRIVACY_PUBLIC
  end

  def name_candidate
    Visualization::NameGenerator.new(current_user)
                                .name(params[:name])
  end

  def tables_by_map_id(map_ids)
    Hash[ ::Table.where(map_id: map_ids).map { |table| [table.map_id, table] } ]
  end

  def synchronizations_by_table_name(table_data)
    # TODO: Check for organization visualizations
    Hash[
      ::Table.db.fetch(
        'SELECT * FROM synchronizations WHERE user_id = ? AND name IN ?',
        current_user.id,
        table_data.map{ |table|
          table[:name]
        }
      ).all.map { |s| [s[:name], s] }
    ]
  end

  def rows_and_sizes_for(table_data)
    data = Hash.new
    table_data.each { |table|
      row = current_user.in_database.fetch(%Q{
        SELECT
          relname AS table_name,
          pg_total_relation_size(? || '.' || relname) AS total_relation_size,
          reltuples::integer AS reltuples
        FROM pg_class
        WHERE relname=?
      },
      table[:schema],
      table[:name]
      ).first
      if row.nil?
        # don't break whole dashboard
        data[table[:name]] = {
          size: nil,
          rows: nil
        }
      else
        data[row[:table_name]] = {
          size: row[:total_relation_size].to_i / 2,
          rows: row[:reltuples]
        }
      end
    }
    data
  end
end

