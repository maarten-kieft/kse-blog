FROM ruby:3.4.2

WORKDIR /mnt
RUN gem update
RUN gem install bundler
RUN gem install jekyll
ENTRYPOINT jekyll serve --host 0.0.0.0 --force_polling