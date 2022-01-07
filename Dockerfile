FROM ruby:3.0.2

MAINTAINER James Hu <hello@james.hu>

ENV SCRIPT_ROOT /srv
RUN mkdir -p $SCRIPT_ROOT

WORKDIR $SCRIPT_ROOT

COPY Gemfile $RAILS_ROOT
COPY Gemfile.lock $RAILS_ROOT

RUN bundle install

COPY . $RAILS_ROOT

CMD bundle exec ruby app.rb
