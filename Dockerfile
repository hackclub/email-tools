FROM ruby:3.3.13

# Install dependencies
RUN apt-get update -qq && apt-get install -y \
    postgresql-client \
    nodejs \
    npm \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install bundler (matching Gemfile.lock version)
RUN gem install bundler -v 2.7.2

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock* ./

# Configure bundler to use system path
RUN bundle config set --local path /usr/local/bundle

# Install gems
RUN bundle install --jobs 4 --retry 3

# Create wrapper scripts for common Rails commands so they work without bundle exec
RUN echo '#!/bin/bash\nbundle exec rails "$@"' > /usr/local/bin/rails && \
    chmod +x /usr/local/bin/rails && \
    echo '#!/bin/bash\nbundle exec rake "$@"' > /usr/local/bin/rake && \
    chmod +x /usr/local/bin/rake && \
    echo '#!/bin/bash\nbundle exec rspec "$@"' > /usr/local/bin/rspec && \
    chmod +x /usr/local/bin/rspec

# Ensure /usr/local/bin comes before bundler's bin directory in PATH
ENV PATH="/usr/local/bin:/usr/local/bundle/ruby/3.3.0/bin:${PATH}"

# Copy entrypoint script
COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh

# Copy application code (required for production images without bind mounts)
COPY . .

# Precompile assets for production
# Set a dummy SECRET_KEY_BASE for asset precompilation (not used for serving)
# RAILS_ENV is set only for this RUN command to avoid persisting it in the image
RUN RAILS_ENV=production SECRET_KEY_BASE=dummy_secret_key_base_for_asset_precompilation_only bundle exec rails assets:precompile

ENTRYPOINT ["entrypoint.sh"]

# Expose port
EXPOSE 3000

# Default command
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
