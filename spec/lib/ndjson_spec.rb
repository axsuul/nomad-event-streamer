require "spec_helper"

require_relative "../../lib/ndjson"

describe NDJSON do
  let(:ndjson) { NDJSON.new }

  describe "#parse_partial" do
    it "parse valid JSON by itself" do
      json_partial_1 = %({"a":"0"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)

      expect(collection).to contain_exactly(
        { "a" => "0" },
      )
    end

    it "can parse multiple parts" do
      json_partial_1 = %({"a":")
      json_partial_2 = %(0", ")
      json_partial_3 = %(b":)
      json_partial_4 = %("1"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)
      collection += ndjson.parse_partial(json_partial_3)
      collection += ndjson.parse_partial(json_partial_4)

      expect(collection).to contain_exactly(
        { "a" => "0", "b" => "1" },
      )
    end

    it "can parse with incomplete head and complete tail partial" do
      json_partial_1 = %(:"0"}\n)
      json_partial_2 = %({"b":"1"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)

      expect(collection).to contain_exactly(
        { "b" => "1" },
      )
    end

    it "can parse with incomplete head and incomplete tail partial" do
      json_partial_1 = %("a":"0"}\n{"b":"1")
      json_partial_2 = %(}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)

      expect(collection).to contain_exactly(
        { "b" => "1" },
      )
    end

    it "can work with multiple incomplete partials" do
      json_partial_1 = %({"a":)
      json_partial_2 = %("0")
      json_partial_3 = %(}\n{"b":"1"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)
      collection += ndjson.parse_partial(json_partial_3)

      expect(collection).to contain_exactly(
        { "a" => "0" },
        { "b" => "1" },
      )
    end

    it "can work with complete and blank partials" do
      json_partial_1 = %({"a":"0"}\n{"b":"1"}\n)
      json_partial_2 = %()
      json_partial_3 = %({"c":"2"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)
      collection += ndjson.parse_partial(json_partial_3)

      expect(collection).to contain_exactly(
        { "a" => "0" },
        { "b" => "1" },
        { "c" => "2" },
      )
    end

    it "can work with mix of incomplete and complete partials" do
      json_partial_1 = %("a":"0"}\n{"b":"1"}\n{"c":)
      json_partial_2 = %("2"}\n{"d":"3"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)

      expect(collection).to contain_exactly(
        { "b" => "1" },
        { "c" => "2" },
        { "d" => "3" },
      )
    end

    it "can parse each partial that is incomplete" do
      json_partial_1 = %({"a":)
      json_partial_2 = %("0"}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)

      expect(collection).to contain_exactly(
        { "a" => "0" },
      )
    end

    it "can parse just new lines" do
      json_partial_1 = %({})
      json_partial_2 = %(\n{}\n)
      json_partial_3 = %({}\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)
      collection += ndjson.parse_partial(json_partial_3)

      expect(collection).to contain_exactly(
        {},
        {},
        {},
      )
    end

    it "can parse new line on its own" do
      json_partial_1 = %({})
      json_partial_2 = %(\n)

      collection = []
      collection += ndjson.parse_partial(json_partial_1)
      collection += ndjson.parse_partial(json_partial_2)

      expect(collection).to contain_exactly(
        {},
      )
    end
  end
end
