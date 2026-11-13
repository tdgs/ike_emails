defmodule IkeEmails.Bank.Alpha.DetailsTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Details

  # The shape of a real getAggregatedAccountStatements details response
  @details_response """
  {
    "ResultCode": 0,
    "CurrentPageIndex": "",
    "HasMore": false,
    "ReplyRecords": 1,
    "TotalRecords": 1,
    "LastExtraitKey": null,
    "Statements": [
      {
        "Amount": 18.01,
        "AmountSign": "Χ",
        "EntryDate": "5/10/2026 12:00:00 πμ",
        "HasCumulative": false,
        "Reason": "SOME SHOP",
        "StatementDetails": [
          {
            "AdditionalInformation": "",
            "Amount": 18.01,
            "AmountSign": "Χ",
            "ConversionDetails": "20,00 USD",
            "IBAN": "GR00",
            "Reason": "SOME SHOP",
            "SenderDetails": "SOME SHOP SUBSCR",
            "TransactionDate": "2026-10-05T00:00:00+03:00",
            "TransactionReference": "202610050993559457",
            "ValueDate": "2026-10-01T00:00:00+03:00"
          }
        ],
        "TransactionUN": "202610050993559457",
        "Valeur": "1/10/2026 12:00:00 πμ"
      }
    ]
  }
  """

  describe "parse/1" do
    test "reads the details of a response of the bank, by transaction id" do
      assert Details.parse(%{"202610050993559457" => @details_response}) ==
               {:ok,
                %{
                  "202610050993559457" => %Detail{
                    conversion_details: "20,00 USD",
                    sender_details: "SOME SHOP SUBSCR",
                    additional_information: ""
                  }
                }}
    end

    test "takes a text that is null or missing as an empty one, and joins the texts of several entries" do
      responses = %{
        "a" => """
        {"Statements": [{"StatementDetails": [
          {"ConversionDetails": null, "SenderDetails": "x"},
          {"SenderDetails": "y", "AdditionalInformation": "note"}
        ]}]}
        """,
        "b" => ~s({"Statements": [{"StatementDetails": []}]})
      }

      assert Details.parse(responses) ==
               {:ok,
                %{
                  "a" => %Detail{
                    conversion_details: "",
                    sender_details: "x | y",
                    additional_information: "note"
                  },
                  "b" => %Detail{
                    conversion_details: "",
                    sender_details: "",
                    additional_information: ""
                  }
                }}
    end

    test "joins the texts of several statements too, each field on its own" do
      response = """
      {"Statements": [
        {"StatementDetails": [{"SenderDetails": "x", "ConversionDetails": "1,00 USD"}]},
        {"StatementDetails": [{"SenderDetails": "y"}]}
      ]}
      """

      assert {:ok, %{"a" => detail}} = Details.parse(%{"a" => response})
      assert detail.sender_details == "x | y"
      assert detail.conversion_details == "1,00 USD"
    end

    test "leaves out the parts that are empty from a join, and only those" do
      response = """
      {"Statements": [{"StatementDetails": [
        {"SenderDetails": ""},
        {"SenderDetails": "x"},
        {"SenderDetails": null},
        {"SenderDetails": " "},
        {"SenderDetails": "y"}
      ]}]}
      """

      assert {:ok, %{"a" => detail}} = Details.parse(%{"a" => response})
      assert detail.sender_details == "x |   | y"
    end

    test "gives the details of nothing for no responses" do
      assert Details.parse(%{}) == {:ok, %{}}
    end

    test "gives empty details for a response with no statements" do
      assert Details.parse(%{"a" => ~s({"Statements": []})}) == {:ok, %{"a" => %Detail{}}}
    end

    test "fails all of them when one response is not what the bank sends" do
      good = @details_response

      for bad <- [
            "not json",
            "",
            "[]",
            "{}",
            ~s({"Statements": null}),
            ~s({"Statements": [{}]}),
            ~s({"Statements": [{"StatementDetails": null}]}),
            ~s({"Statements": [{"StatementDetails": [{"SenderDetails": 5}]}]}),
            ~s({"Statements": [{"StatementDetails": ["x"]}]})
          ] do
        assert Details.parse(%{"1" => good, "2" => bad}) == {:error, :unexpected_response}
      end
    end

    test "fails for what is not a map of texts" do
      assert Details.parse(%{"1" => nil}) == {:error, :unexpected_response}
      assert Details.parse(%{"1" => %{"Statements" => []}}) == {:error, :unexpected_response}
      assert Details.parse("{}") == {:error, :unexpected_response}
    end
  end
end
