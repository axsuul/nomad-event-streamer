# Nomad Event Streamer

Streams HashiCorp Nomad events to your favorite destinations:

* Discord

<img width="562" alt="CleanShot 2022-01-07 at 11 40 24@2x" src="https://user-images.githubusercontent.com/187961/148598168-7b5c08e6-e5f8-4ff0-980d-38a3064a2f72.png">


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
