class SyncSourcesController < ApplicationController
  before_action :set_sync_source, only: [ :show, :edit, :update, :destroy ]

  def index
    @source = params[:source].presence

    unless @source.present?
      @error = "Source parameter is required. Please select a source type."
      @source_items = []
      @sync_sources_by_source_id = {}
      @ignored = Set.new
      @matching_ignores_by_source_id = {}
      @pattern_ignores = []
      @deleted_sources = []
      return
    end

    # Fetch sources using adapter pattern
    begin
      adapter = adapter_for_source(@source)
      if adapter
        source_items = adapter.list_ids_with_names
        @source_items = source_items.map { |item| { "id" => item[:id], "name" => item[:name] } }
      else
        @source_items = []
        @error = "No adapter available for source: #{@source}"
      end

      @sync_sources_by_source_id = SyncSource.where(source: @source).index_by(&:source_id)

      # Build ignored set: use centralized IgnoreMatcher service
      @matcher = IgnoreMatcher.for(source: @source)

      @ignored = Set.new
      @source_items.each do |source_item|
        if @matcher.match?(source_item["id"])
          @ignored.add(source_item["id"])
        end
      end

      @pattern_ignores = SyncSourceIgnore.where(source: @source).to_a

      # Load deleted sources for UI
      @deleted_sources = SyncSource.only_deleted.where(source: @source).order(:display_name)

      # Pre-calculate matching ignores for each ignored source to avoid N+1 in view
      @matching_ignores_by_source_id = {}
      @source_items.each do |source_item|
        if @ignored.include?(source_item["id"])
          @matching_ignores_by_source_id[source_item["id"]] = @matcher.matching_ignores(source_item["id"])
        end
      end

      # Sort sources to show active sync sources on top
      @source_items.sort_by! do |source_item|
        sync_source = @sync_sources_by_source_id[source_item["id"]]
        if sync_source
          # Active sync sources (consecutive_failures == 0) come first
          sync_source.consecutive_failures == 0 ? 0 : 1
        else
          # Sources with no sync source come last
          2
        end
      end
    rescue => e
      @error = "Failed to fetch sources for #{@source}: #{e.message}"
      @source_items = []
      @sync_sources_by_source_id = {}
      @ignored = Set.new
      @matching_ignores_by_source_id = {}
      @pattern_ignores = []
      @matcher = IgnoreMatcher.for(source: @source) # Initialize even on error for view safety
    end
  end

  def show
  end

  def new
    @source = params[:source].presence

    unless @source.present?
      redirect_to admin_sync_sources_path, alert: "Source parameter is required."
      return
    end

    @sync_source = sync_source_class_for(@source).new
    @source_id = params[:source_id]

    # Fetch available sources for dropdown (only for Airtable currently)
    if @source == "airtable"
      begin
        adapter = adapter_for_source(@source)
        if adapter
          @available_sources = adapter.list_ids_with_names.map { |item| { "id" => item[:id], "name" => item[:name] } }
        else
          @available_sources = []
        end
      rescue => e
        @error = "Failed to fetch sources: #{e.message}"
        @available_sources = []
      end
    else
      @available_sources = []
    end
  end

  def create
    @source = params[:source].presence

    unless @source.present?
      redirect_to admin_sync_sources_path, alert: "Source parameter is required."
      return
    end

    @sync_source = sync_source_class_for(@source).new(sync_source_params)
    @sync_source.source = @source

    # Set display_name from source name if available (using adapter)
    if @sync_source.source_id.present?
      begin
        adapter = adapter_for_source(@source)
        if adapter
          source_items = adapter.list_ids_with_names
          source_item = source_items.find { |item| item[:id] == @sync_source.source_id }
          if source_item && source_item[:name]
            @sync_source.display_name = source_item[:name]
            @sync_source.display_name_updated_at = Time.current
          end
        end
      rescue => e
        # Log error but don't fail creation if we can't fetch source name
        Rails.logger.warn("Failed to fetch source name for #{@sync_source.source_id}: #{e.message}")
      end
    end

    if @sync_source.save
      redirect_to admin_sync_source_path(@sync_source), notice: "Sync source was successfully created."
    else
      begin
        adapter = adapter_for_source(@source)
        if adapter
          @available_sources = adapter.list_ids_with_names.map { |item| { "id" => item[:id], "name" => item[:name] } }
        else
          @available_sources = []
        end
      rescue => e
        @error = "Failed to fetch sources: #{e.message}"
        @available_sources = []
      end
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @sync_source.update(sync_source_params)
      redirect_to admin_sync_source_path(@sync_source), notice: "Sync source was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @sync_source.soft_delete!(reason: :manual)
    redirect_to admin_sync_sources_path(source: @sync_source.source), notice: "Sync source was archived (soft-deleted)."
  end

  def restore
    ss = SyncSource.with_deleted.find_by(id: params[:id])
    if ss.nil?
      redirect_to admin_sync_sources_path, alert: "Sync source not found."
    elsif ss.deleted_at.present?
      ss.restore!
      redirect_to admin_sync_sources_path(source: ss.source), notice: "Sync source restored."
    else
      redirect_to admin_sync_sources_path(source: ss.source), alert: "Sync source is not deleted."
    end
  end

  def ignore
    source = params[:source].presence
    source_id = params[:source_id]
    pattern = params[:pattern] # For UI form - pattern field

    unless source.present?
      redirect_to admin_sync_sources_path, alert: "Source parameter is required."
      return
    end

    # Use pattern if provided (from UI form), otherwise use source_id (from button click)
    regex_pattern = pattern.presence || source_id

    unless regex_pattern.present?
      redirect_to admin_sync_sources_path(source: source), alert: "Pattern/Source ID is required"
      return
    end

    # Create ignore record - source_id is always treated as regex
    ignore_record = SyncSourceIgnore.new(
      source: source,
      source_id: regex_pattern,
      reason: params[:reason].presence
    )

    unless ignore_record.save
      redirect_to admin_sync_sources_path(source: source), alert: "Failed to create ignore pattern: #{ignore_record.errors.full_messages.join(', ')}"
      return
    end

    # Soft-delete any active sync sources that match this pattern
    new_matcher = IgnoreMatcher.new([ ignore_record ])

    # Pluck IDs and source_ids to avoid loading all records into memory
    source_ids_to_check = SyncSource.where(source: source).pluck(:id, :source_id)

    matching_source_ids = source_ids_to_check.filter_map do |id, source_id|
      id if new_matcher.match?(source_id)
    end

    retired_count = 0
    if matching_source_ids.any?
      # Use update_all for a single efficient DB query
      retired_count = SyncSource.where(id: matching_source_ids).update_all(
        deleted_at: Time.current,
        deleted_reason: SyncSource.deleted_reasons[:ignored_pattern],
        updated_at: Time.current
      )
    end

    notice = retired_count > 0 ? "Created ignore pattern '#{regex_pattern}' and removed #{retired_count} sync source(s)" : "Created ignore pattern '#{regex_pattern}'"

    redirect_to admin_sync_sources_path(source: source), notice: notice
  end

  def unignore
    source = params[:source].presence
    ignore_id = params[:ignore_id]

    unless source.present?
      redirect_to admin_sync_sources_path, alert: "Source parameter is required."
      return
    end

    if ignore_id.present?
      # Delete by ID (preferred method - always works correctly)
      ignore_record = SyncSourceIgnore.find_by(id: ignore_id, source: source)
      if ignore_record
        pattern_text = ignore_record.source_id
        ignore_record.destroy
        redirect_to admin_sync_sources_path(source: source), notice: "Removed ignore pattern '#{pattern_text}'"
      else
        redirect_to admin_sync_sources_path(source: source), alert: "Ignore record not found"
      end
    else
      redirect_to admin_sync_sources_path(source: source), alert: "Ignore ID is required"
    end
  end

  private

  def set_sync_source
    @sync_source = SyncSource.find(params[:id])
  end

  def sync_source_params
    # Handle both sync_source and airtable_sync_source parameter names
    params.require(params[:sync_source] ? :sync_source : :airtable_sync_source).permit(:source_id, :poll_interval_seconds, :poll_jitter)
  end

  def adapter_for_source(source)
    case source
    when "airtable"
      Discovery::AirtableAdapter.new
    else
      nil
    end
  end

  def sync_source_class_for(source)
    case source
    when "airtable"
      AirtableSyncSource
    else
      SyncSource
    end
  end

  def available_sources
    # Return list of available source types
    # Currently only airtable is supported, but this makes it easy to add more
    [ "airtable" ]
  end
  helper_method :available_sources
end
