# Nomad Event Streamer

Streams HashiCorp Nomad events to your favorite destination.

* Discord

This project is under active development. Use at your own discretion!

## Usage

Refer to [app.rb](./app.rb) for supported environment variables. 

## Docker

Each commit has a [Docker image](https://github.com/axsuul/nomad-event-streamer/pkgs/container/nomad-event-streamer) built for it or use `ghcr.io/axsuul/nomad-event-streamer:latest`.

## Development

`bundle` then run tests with

```shell
bundle exec rspec
```
