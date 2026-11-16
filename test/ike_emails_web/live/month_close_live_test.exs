defmodule IkeEmailsWeb.MonthCloseLiveTest do
  # The model is answered through the configuration of the application, see
  # IkeEmails.LLMStub
  use IkeEmailsWeb.ConnCase, async: false

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.ElorusStub
  alias IkeEmails.LLMStub
  alias IkeEmails.MonthClose
  alias IkeEmails.MonthClose.Proposal
  alias IkeEmails.Repo

  setup :register_and_log_in_user

  # The run is a task: the page shows what it proposed when it is done
  defp wait_for(view, selector, tries \\ 500) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} did not show up")
      true -> Process.sleep(10) && wait_for(view, selector, tries - 1)
    end
  end

  defp run(view, transaction) do
    view |> element("#run-month-close") |> render_click()
    wait_for(view, "#proposal-#{transaction.id}")
    Repo.get_by!(Proposal, transaction_id: transaction.id)
  end

  defp propose(transaction, arguments) do
    LLMStub.tool_use([
      {"propose",
       Map.merge(%{"transaction_id" => transaction.id, "rationale" => "It fits."}, arguments)}
    ])
  end

  test "has no button without a model", %{conn: conn, scope: scope} do
    settings = Application.fetch_env!(:ike_emails, MonthClose)
    on_exit(fn -> Application.put_env(:ike_emails, MonthClose, settings) end)
    Application.put_env(:ike_emails, MonthClose, model: nil)

    transaction_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

    refute has_element?(view, "#run-month-close")
  end

  test "has no button when every transaction is settled", %{conn: conn, scope: scope} do
    transaction = transaction_fixture(scope)
    invoice_fixture(scope, %{}, transaction_ids: [transaction.id])
    {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

    refute has_element?(view, "#run-month-close")
  end

  test "a run shows a proposal, which approving applies", %{conn: conn, scope: scope} do
    transaction = transaction_fixture(scope)
    invoice = invoice_fixture(scope)

    LLMStub.script([
      LLMStub.tool_use([{"find_invoices", %{"transaction_id" => transaction.id}}]),
      propose(transaction, %{"kind" => "attach", "invoice_id" => invoice.id}),
      LLMStub.text()
    ])

    {:ok, view, _html} = live(conn, ~p"/?month=2026-10")
    proposal = run(view, transaction)

    assert has_element?(view, "#proposal-#{transaction.id}[data-kind=attach]")
    refute has_element?(view, "#transactions-#{transaction.id}-invoice-#{invoice.id}")

    view |> element("#approve-proposal-#{proposal.id}") |> render_click()

    refute has_element?(view, "#proposal-#{transaction.id}")
    assert has_element?(view, "#transactions-#{transaction.id}-invoice-#{invoice.id}")
    assert has_element?(view, "#transactions-#{transaction.id}[data-status=invoiced]")
  end

  test "rejecting a proposal changes nothing", %{conn: conn, scope: scope} do
    transaction = transaction_fixture(scope)

    LLMStub.script([
      propose(transaction, %{"kind" => "no_invoice", "note" => "bank fee"}),
      LLMStub.text()
    ])

    {:ok, view, _html} = live(conn, ~p"/?month=2026-10")
    proposal = run(view, transaction)

    assert has_element?(view, "#proposal-#{transaction.id}[data-kind=no_invoice]")

    view |> element("#reject-proposal-#{proposal.id}") |> render_click()

    refute has_element?(view, "#proposal-#{transaction.id}")
    assert has_element?(view, "#transactions-#{transaction.id}[data-status=missing]")
  end

  test "a proposal is still there when the month is opened again", %{conn: conn, scope: scope} do
    transaction = transaction_fixture(scope)

    {:ok, _proposal} =
      MonthClose.put_proposal(scope, transaction, %{}, %{
        "kind" => "no_invoice",
        "note" => "bank fee",
        "rationale" => "It is a commission of the bank."
      })

    {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

    assert has_element?(view, "#proposal-#{transaction.id}")
  end

  defp elorus_proposal(scope) do
    transaction = transaction_fixture(scope, %{"amount" => "100.00"})

    {:ok, proposal} =
      MonthClose.put_proposal(scope, transaction, %{elorus_invoice: ElorusStub.invoice_json()}, %{
        "kind" => "import_elorus",
        "rationale" => "The amount and the client fit."
      })

    {transaction, proposal}
  end

  describe "approving an invoice of Elorus" do
    setup :configure_settings

    test "imports it", %{conn: conn, scope: scope} do
      ElorusStub.stub()
      {transaction, proposal} = elorus_proposal(scope)
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "#proposal-#{transaction.id}[data-kind=import_elorus]")
      view |> element("#approve-proposal-#{proposal.id}") |> render_click()

      wait_for(view, "#transactions-#{transaction.id}[data-status=invoiced]")
      refute has_element?(view, "#proposal-#{transaction.id}")
    end
  end

  describe "approving an invoice of Elorus while it is locked" do
    test "says what to do, and keeps the proposal", %{conn: conn, scope: scope} do
      settings_fixture(scope)
      {transaction, proposal} = elorus_proposal(scope)
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view |> element("#approve-proposal-#{proposal.id}") |> render_click()

      wait_for(view, "#flash-error")
      assert render(view) =~ "Unlock Elorus first"
      assert has_element?(view, "#proposal-#{transaction.id}")
      assert has_element?(view, "#transactions-#{transaction.id}[data-status=income]")
    end
  end
end
