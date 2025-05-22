# syntax=docker/dockerfile:1
# This Dockerfile is for production with a Ruby Telegram bot and PostgreSQL.

# Make sure RUBY_VERSION matches the Ruby version you're using
ARG RUBY_VERSION=3.2.3
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Install necessary system packages for the bot to run (including PostgreSQL client)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq-dev build-essential && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Install any necessary gems and dependencies
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq-dev libyaml-dev pkg-config git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Create the application directory
WORKDIR /app

# Copy the Gemfile and Gemfile.lock if they exist, and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy the rest of the application code (bot.rb and other files)
COPY . ./

# Final stage for the bot image
FROM base

# Create app directory and copy the dependencies
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 app && \
    useradd app --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R app:app /app

# Switch to non-root user
USER 1000:1000

# Entrypoint for running the bot script
ENTRYPOINT ["bash", "-c", "RAILS_ENV=production bundle exec rake db:migrate && ruby /app/bot.rb"]

# Expose necessary ports if needed
EXPOSE 8080