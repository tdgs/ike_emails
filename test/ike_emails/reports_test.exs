defmodule IkeEmails.ReportsTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Reports
  alias IkeEmails.Storage.InMemory

  setup :create_user_scope

  defp unzip(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, body} -> {List.to_string(name), body} end)
  end

  defp names(zip), do: zip |> unzip() |> Map.keys() |> Enum.sort()

  defp outgoing_fixture(scope, receiver, attrs \\ %{}) do
    invoice_fixture(
      scope,
      Map.merge(%{"issuer_name" => "My Business", "receiver_name" => receiver}, attrs)
    )
  end

  describe "month_zip/2" do
    test "has the statement, and the invoices received and issued apart", %{scope: scope} do
      statement = statement_fixture(scope)
      expense = invoice_fixture(scope, %{"issuer_name" => "Elorus", "date" => "2026-10-03"})
      income = outgoing_fixture(scope, "Acme", %{"date" => "2026-10-09"})

      assert {:ok, "report-2026-10.zip", zip} = Reports.month_zip(scope, ~D[2026-10-15])

      assert names(zip) == [
               "incoming/2026-10-03-Elorus-#{expense.id}.pdf",
               "outgoing/2026-10-09-Acme-#{income.id}.pdf",
               "statement-2026-10.pdf"
             ]

      files = unzip(zip)
      assert files["statement-2026-10.pdf"] == elem(InMemory.get(statement.file_key), 0)

      assert files["incoming/2026-10-03-Elorus-#{expense.id}.pdf"] ==
               elem(InMemory.get(expense.file_key), 0)

      assert files["outgoing/2026-10-09-Acme-#{income.id}.pdf"] ==
               elem(InMemory.get(income.file_key), 0)
    end

    test "names an invoice after its issuer, or its receiver when issued", %{scope: scope} do
      expense = invoice_fixture(scope, %{"issuer_name" => "Τιμολόγιο ΑΕ"})
      income = outgoing_fixture(scope, "Πελάτης ΕΠΕ")
      statement_fixture(scope)

      {:ok, _name, zip} = Reports.month_zip(scope, ~D[2026-10-01])

      assert "incoming/2026-10-09-Τιμολόγιο ΑΕ-#{expense.id}.pdf" in names(zip)
      assert "outgoing/2026-10-09-Πελάτης ΕΠΕ-#{income.id}.pdf" in names(zip)
    end

    test "cleans a name so that it makes no path of its own", %{scope: scope} do
      statement_fixture(scope)
      invoice = invoice_fixture(scope, %{"issuer_name" => "ACME/Co: ..\\Ltd"})

      {:ok, _name, zip} = Reports.month_zip(scope, ~D[2026-10-01])

      assert names(zip) == [
               "incoming/2026-10-09-ACME_Co_ .._Ltd-#{invoice.id}.pdf",
               "statement-2026-10.pdf"
             ]
    end

    test "has both invoices of an issuer dated the same day", %{scope: scope} do
      statement_fixture(scope)
      [first, second] = for _ <- 1..2, do: invoice_fixture(scope)

      {:ok, _name, zip} = Reports.month_zip(scope, ~D[2026-10-01])

      assert "incoming/2026-10-09-Elorus-#{first.id}.pdf" in names(zip)
      assert "incoming/2026-10-09-Elorus-#{second.id}.pdf" in names(zip)
    end

    test "has the invoices dated in the month, first and last day included", %{scope: scope} do
      statement_fixture(scope)
      dates = ["2026-09-30", "2026-10-01", "2026-10-31", "2026-11-01"]

      [_september, first, last, _november] =
        for d <- dates, do: invoice_fixture(scope, %{"date" => d})

      {:ok, _name, zip} = Reports.month_zip(scope, ~D[2026-10-01])

      assert names(zip) == [
               "incoming/2026-10-01-Elorus-#{first.id}.pdf",
               "incoming/2026-10-31-Elorus-#{last.id}.pdf",
               "statement-2026-10.pdf"
             ]
    end

    test "has only what is of the user", %{scope: scope} do
      statement_fixture(scope)
      other = user_scope_fixture()
      statement_fixture(other)
      invoice_fixture(other)

      {:ok, _name, zip} = Reports.month_zip(scope, ~D[2026-10-01])

      assert names(zip) == ["statement-2026-10.pdf"]
    end

    test "has no report for a month without a statement", %{scope: scope} do
      invoice_fixture(scope)
      statement_fixture(scope, "2026-09")

      assert Reports.month_zip(scope, ~D[2026-10-01]) == {:error, :no_statement}
    end

    test "says which PDF could not be read", %{scope: scope} do
      statement_fixture(scope)
      invoice = invoice_fixture(scope)
      InMemory.delete(invoice.file_key)

      assert Reports.month_zip(scope, ~D[2026-10-01]) ==
               {:error, {:storage, invoice.file_key, :not_found}}
    end
  end
end
