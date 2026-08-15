class EmailsController < ApplicationController
  EMAILS_PER_PAGE = 1000

  def index
    @query = params[:q].to_s.strip
    @page = params[:page].to_i
    @page = 1 if @page < 1

    scope = LoopsContactChangeAudit.all
    if @query.present?
      scope = scope.where(
        "email_normalized ILIKE ?",
        "%#{LoopsContactChangeAudit.sanitize_sql_like(@query)}%"
      )
    end

    @total_count = scope.distinct.count(:email_normalized)
    @total_pages = [ (@total_count.to_f / EMAILS_PER_PAGE).ceil, 1 ].max
    @page = @total_pages if @page > @total_pages

    # Get distinct emails ordered by most recent occurred_at
    @emails = scope
      .group(:email_normalized)
      .order(Arel.sql("MAX(occurred_at) DESC"))
      .limit(EMAILS_PER_PAGE)
      .offset((@page - 1) * EMAILS_PER_PAGE)
      .pluck(:email_normalized)
  end

  def show
    # Rails automatically URL-decodes params
    # For wildcard routes, params[:email] is a string (emails don't contain slashes)
    email_from_params = params[:email].is_a?(Array) ? params[:email].join("/") : params[:email].to_s

    # Normalize the email to match how it's stored in the database (lowercase, trimmed)
    @email = EmailNormalizer.normalize(email_from_params)

    audits = LoopsContactChangeAudit.for_email(@email).order(occurred_at: :desc)

    # Bucket audits by 5-minute intervals
    @bucketed_audits = audits.group_by do |audit|
      # Round down to nearest 5-minute interval
      timestamp = audit.occurred_at
      minutes = timestamp.min
      rounded_minutes = (minutes / 5) * 5
      bucket_time = timestamp.change(min: rounded_minutes, sec: 0, usec: 0)
      bucket_time
    end
  end
end
