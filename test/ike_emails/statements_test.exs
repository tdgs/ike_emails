defmodule IkeEmails.StatementsTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Statements
  alias IkeEmails.Statements.Statement
  alias IkeEmails.Storage.InMemory

  setup :create_user_scope

  describe "list_statements/1" do
    test "has the latest month first", %{scope: scope} do
      [september, october, august] =
        Enum.map(["2026-09", "2026-10", "2026-08"], &statement_fixture(scope, &1))

      assert Enum.map(Statements.list_statements(scope), & &1.id) ==
               [october.id, september.id, august.id]
    end

    test "has only the statements of the user", %{scope: scope} do
      mine = statement_fixture(scope)
      statement_fixture(user_scope_fixture())

      assert Enum.map(Statements.list_statements(scope), & &1.id) == [mine.id]
    end
  end

  describe "get_statement!/2" do
    test "gets a statement of the user", %{scope: scope} do
      statement = statement_fixture(scope)

      assert Statements.get_statement!(scope, statement.id).id == statement.id
    end

    test "raises for the statement of another user", %{scope: scope} do
      other = statement_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> Statements.get_statement!(scope, other.id) end
    end
  end

  describe "put_statement/4" do
    test "stores the PDF as the statement of the month", %{scope: scope} do
      pdf = pdf_fixture()

      assert {:ok, :created, statement} =
               Statements.put_statement(scope, "2026-10", pdf, "statement.pdf")

      assert statement.month == ~D[2026-10-01]
      assert statement.file_name == "statement.pdf"
      assert statement.file_size == byte_size(pdf)

      assert statement.file_key ==
               "statements/#{scope.user.id}/2026-10-#{statement.file_sha256}.pdf"

      assert {^pdf, "application/pdf"} = InMemory.get(statement.file_key)
      assert Statements.get_statement(scope, ~D[2026-10-17]).id == statement.id
    end

    test "keeps the name of the file, not the path it was sent with", %{scope: scope} do
      assert {:ok, :created, %{file_name: "oct.pdf"}} =
               Statements.put_statement(scope, "2026-10", pdf_fixture(), "../../tmp/oct.pdf")
    end

    test "the same PDF again changes nothing", %{scope: scope} do
      pdf = pdf_fixture()
      {:ok, :created, statement} = Statements.put_statement(scope, "2026-10", pdf, "a.pdf")

      assert {:ok, :existing, existing} = Statements.put_statement(scope, "2026-10", pdf, "b.pdf")

      assert existing.id == statement.id
      assert existing.file_name == "a.pdf"
      assert existing.updated_at == statement.updated_at
      assert InMemory.exists?(statement.file_key)
      assert Repo.aggregate(Statement, :count) == 1
    end

    test "a different PDF replaces the statement and its object", %{scope: scope} do
      old = statement_fixture(scope)
      new_pdf = pdf_fixture()

      assert {:ok, :replaced, statement} =
               Statements.put_statement(scope, "2026-10", new_pdf, "corrected.pdf")

      assert statement.id == old.id
      assert statement.file_name == "corrected.pdf"
      assert statement.file_key != old.file_key
      assert {^new_pdf, "application/pdf"} = InMemory.get(statement.file_key)
      refute InMemory.exists?(old.file_key)
      assert Repo.aggregate(Statement, :count) == 1
    end

    test "each month has its own statement", %{scope: scope} do
      october = statement_fixture(scope, "2026-10")
      november = statement_fixture(scope, "2026-11")

      assert october.id != november.id
      assert InMemory.exists?(october.file_key)
      assert InMemory.exists?(november.file_key)
      assert Statements.get_statement(scope, ~D[2026-11-01]).id == november.id
    end

    test "another user has a statement of the same month", %{scope: scope} do
      other = user_scope_fixture()

      mine = statement_fixture(scope)
      theirs = statement_fixture(other)

      assert mine.id != theirs.id
      assert Statements.get_statement(scope, ~D[2026-10-01]).id == mine.id
      assert Statements.get_statement(other, ~D[2026-10-01]).id == theirs.id
    end

    test "refuses what is not a PDF", %{scope: scope} do
      assert {:error, :not_a_pdf} =
               Statements.put_statement(scope, "2026-10", "<html></html>", "a.pdf")

      assert Repo.aggregate(Statement, :count) == 0
    end

    test "refuses a PDF that is too large", %{scope: scope} do
      pdf = "%PDF-" <> :binary.copy("0", Statements.max_pdf_bytes())

      assert {:error, :too_large} = Statements.put_statement(scope, "2026-10", pdf, "a.pdf")
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "refuses a month that is not YYYY-MM and stores nothing", %{scope: scope} do
      pdf = pdf_fixture()
      sha256 = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

      for month <- ["2026-13", "2026-00", "2026-10-05", "2026-1", "october", "", nil] do
        assert {:error, changeset} = Statements.put_statement(scope, month, pdf, "a.pdf")
        assert %{month: ["is invalid"]} = errors_on(changeset)
        assert changeset.action == :insert
      end

      assert Repo.aggregate(Statement, :count) == 0
      refute InMemory.exists?("statements/#{scope.user.id}/2026-10-#{sha256}.pdf")
    end
  end
end
