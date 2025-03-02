FROM ruby:3.4.2

WORKDIR /mnt
RUN gem update
RUN gem install bundler
RUN gem install jekyll
ENTRYPOINT bundle install && bundle exec jekyll serve