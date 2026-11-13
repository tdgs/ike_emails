defmodule IkeEmails.Bank.Alpha.GoldenTest do
  use ExUnit.Case, async: true

  # The fixtures in test/fixtures/bank/golden hold inputs and what the Gleam crawler made of
  # them (see the README there). The other tests of this directory say what the modules are
  # meant to do; these say they do what the crawler did, on the same inputs. The rows
  # are matched against the rows already stored by their transaction id, amount and
  # description, so a difference here would store a transaction a second time.

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Details
  alias IkeEmails.Bank.Alpha.EStatements
  alias IkeEmails.Bank.Alpha.Login
  alias IkeEmails.Bank.Alpha.Rows
  alias IkeEmails.Bank.Alpha.Statement
  alias IkeEmails.Bank.Alpha.Statements
  alias IkeEmails.Bank.Alpha.Text

  @fixtures Path.expand("../../../fixtures/bank/golden", __DIR__)

  @row_fields ~w(date value_date description branch transaction_id amount conversion_details sender_details additional_information)a

  # The columns of a row that are nil when the bank has nothing for them
  @optional_fields ~w(branch conversion_details sender_details additional_information)a

  # What the Gleam crawler takes for a month: the digits of a month from 01 to 12
  @month ~r/\A[0-9]{4}-(0[1-9]|1[0-2])\z/

  describe "Text.clean/1" do
    test "cleans every text as the Gleam crawler did" do
      check(fixture("text_clean.json"), 300, fn %{"input" => input, "expected" => expected} ->
        {Text.clean(input), expected}
      end)
    end
  end

  describe "Statements.parse/1 and Rows.build/2" do
    test "make the amount of every line as the Gleam crawler did" do
      check(fixture("amounts.json"), 150, fn %{
                                               "amount" => amount,
                                               "sign" => sign,
                                               "expected" => expected
                                             } ->
        statement =
          ~s({"EntryDate":"5/10/2026","Valeur":"1/10/2026","Reason":"R","Branch":"99",) <>
            ~s("TransactionUN":"1","Amount":#{amount},"AmountSign":#{Jason.encode!(sign)}})

        got =
          case read_rows(~s({"Statements":[#{statement}]}), %{}) do
            %{"rows" => [%{"amount" => amount}]} -> %{"amount" => amount}
            %{"error" => stage} -> %{"error" => stage}
          end

        {got, expected}
      end)
    end

    test "read the lines and make the rows as the Gleam crawler did" do
      check(fixture("rows.json"), 100, fn %{
                                            "statements" => statements,
                                            "details" => details,
                                            "expected" => expected
                                          } ->
        {read_rows(statements, details), expected}
      end)
    end
  end

  describe "EStatements" do
    test "parse, pick the latest and name the file of every list as the Gleam crawler did" do
      check(fixture("estatements.json"), 80, fn %{"body" => body, "expected" => expected} ->
        {read_estatements(body), expected}
      end)
    end
  end

  describe "Login.session_in_use?/1" do
    test "tells every message as the Gleam crawler did" do
      check(fixture("session_in_use.json"), 10, fn %{
                                                     "message" => message,
                                                     "expected" => expected
                                                   } ->
        {Login.session_in_use?(message), expected}
      end)
    end
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # Runs `fun`, which returns `{got, expected}`, on every case, and fails with the first
  # cases that differ. `minimum` is the number of cases the fixture must have, so that an
  # emptied one does not pass.
  defp check(cases, minimum, fun) do
    assert length(cases) >= minimum

    mismatches =
      cases
      |> Enum.with_index()
      |> Enum.flat_map(fn {golden, index} ->
        case fun.(golden) do
          {same, same} -> []
          {got, expected} -> [{index, golden, got, expected}]
        end
      end)

    if mismatches != [] do
      shown =
        mismatches
        |> Enum.take(3)
        |> Enum.map_join("\n\n", fn {index, golden, got, expected} ->
          "case #{index}: #{inspect(golden, limit: :infinity, printable_limit: 1_500)}\n" <>
            "  got:      #{inspect(got, limit: :infinity, printable_limit: 1_500)}\n" <>
            "  expected: #{inspect(expected, limit: :infinity, printable_limit: 1_500)}"
        end)

      flunk(
        "#{length(mismatches)} of #{length(cases)} cases differ from the Gleam crawler:\n\n#{shown}"
      )
    end
  end

  # The same shape as `expected` in rows.json. The Gleam crawler writes an empty text
  # where the bank has nothing, and the rows here may have nil in the columns that can be
  # empty (the Ecto cast of a row turns an empty text into nil anyway), so a nil in one of
  # those is compared as an empty text. Nothing else is normalised.
  defp read_rows(statements_body, details_bodies) do
    with {:statements, {:ok, %{statements: statements}}} <-
           {:statements, Statements.parse(statements_body)},
         {:details, {:ok, details}} <- {:details, Details.parse(details_bodies)},
         {:ok, rows, []} <- Rows.build(statements, details) do
      %{
        "statements" => Enum.map(statements, &statement_map/1),
        "details" => Map.new(details, fn {id, detail} -> {id, detail_map(detail)} end),
        "rows" => Enum.map(rows, &row_map/1)
      }
    else
      {:statements, _} -> %{"error" => "statements"}
      {:details, _} -> %{"error" => "details"}
      other -> %{"unexpected" => inspect(other)}
    end
  end

  defp statement_map(%Statement{} = statement) do
    %{
      "entry_date" => statement.entry_date,
      "value_date" => statement.value_date,
      "reason" => statement.reason,
      "branch" => statement.branch,
      "transaction_id" => statement.transaction_id,
      "detail" => detail_map(statement.detail)
    }
  end

  defp detail_map(nil), do: nil

  defp detail_map(%Detail{} = detail) do
    %{
      "conversion_details" => detail.conversion_details,
      "sender_details" => detail.sender_details,
      "additional_information" => detail.additional_information
    }
  end

  defp row_map(row) do
    assert row |> Map.keys() |> Enum.sort() == Enum.sort(@row_fields)

    Map.new(@row_fields, fn field ->
      value = Map.fetch!(row, field)
      {Atom.to_string(field), if(field in @optional_fields, do: value || "", else: value)}
    end)
  end

  # The same shape as `expected` in estatements.json. The Gleam crawler can also name the
  # month from the file name, and says there is none for a month that is not 01 to 12;
  # this module has only the month of a statement, so the same check is made on it.
  defp read_estatements(body) do
    case EStatements.parse(body) do
      {:ok, estatements} ->
        %{
          "estatements" => Enum.map(estatements, &estatement_map/1),
          "latest" => latest_index(estatements)
        }

      {:error, :unexpected_response} ->
        %{"error" => "unexpected_response"}
    end
  end

  defp estatement_map(estatement) do
    month = EStatements.month(estatement)

    %{
      "id" => estatement.id,
      "date_from" => estatement.date_from,
      "date_to" => estatement.date_to,
      "issued_date" => estatement.issued_date,
      "file_name" => EStatements.file_name(estatement),
      "month" => if(Regex.match?(@month, month), do: month)
    }
  end

  defp latest_index(estatements) do
    case EStatements.latest(estatements) do
      {:ok, latest} -> Enum.find_index(estatements, &(&1 == latest))
      {:error, :none} -> nil
    end
  end
end
