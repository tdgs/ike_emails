defmodule IkeEmails.MonthCloseTest do
  # The model is answered through the configuration of the application, see
  # IkeEmails.LLMStub
  use IkeEmails.DataCase, async: false

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.ElorusStub
  alias IkeEmails.Invoicing
  alias IkeEmails.LLMStub
  alias IkeEmails.MonthClose
  alias IkeEmails.MonthClose.Proposal

  @month ~D[2026-10-01]

  setup do
    %{scope: user_scope_fixture()}
  end

  defp proposal(transaction), do: Repo.get_by(Proposal, transaction_id: transaction.id)

  # The requests that the model got, in their order
  defp requests(found \\ []) do
    receive do
      {:llm_request, body} -> requests([body | found])
    after
      0 -> Enum.reverse(found)
    end
  end

  # The requests to Elorus that the run made, as the stub sends them to the test
  defp elorus_requests(count \\ 0) do
    receive do
      {:elorus_request, _conn} -> elorus_requests(count + 1)
    after
      0 -> count
    end
  end

  defp propose(transaction, arguments) do
    {"propose",
     Map.merge(%{"transaction_id" => transaction.id, "rationale" => "It fits."}, arguments)}
  end

  describe "run/2" do
    test "proposes an invoice that it found, and attaches nothing", %{scope: scope} do
      transaction = transaction_fixture(scope)
      invoice = invoice_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([{"find_invoices", %{"transaction_id" => transaction.id}}]),
        LLMStub.tool_use([
          propose(transaction, %{"kind" => "attach", "invoice_id" => invoice.id})
        ]),
        LLMStub.text()
      ])

      assert MonthClose.run(scope, @month) == {:ok, %{proposed: 1, elorus_skipped?: false}}

      assert %Proposal{kind: :attach, rationale: "It fits."} = proposal = proposal(transaction)
      assert proposal.invoice_id == invoice.id
      assert proposal.user_id == scope.user.id
      assert Banking.get_transaction!(scope, transaction.id).invoices == []

      assert [first, second, _third] = requests()
      assert Enum.map(first["tools"], & &1["name"]) == ["find_invoices", "propose"]
      assert Jason.encode!(first["messages"]) =~ transaction.description
      # The conversation is sent again at every step, so the provider is asked to cache it
      assert Jason.encode!(first) =~ "cache_control"

      assert [{[found], false}] = LLMStub.tool_results(second)
      assert found["id"] == invoice.id
      assert found["same_amount"]
    end

    test "leaves out the transactions that are settled", %{scope: scope} do
      open = transaction_fixture(scope)
      invoiced = transaction_fixture(scope)
      invoice_fixture(scope, %{}, transaction_ids: [invoiced.id])
      exempt = transaction_fixture(scope)
      {:ok, _} = Banking.mark_no_invoice(scope, exempt, "tax")

      LLMStub.script([LLMStub.text()])
      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)

      assert [%{"messages" => messages}] = requests()
      shown = Jason.encode!(messages)
      assert shown =~ open.description
      refute shown =~ invoiced.description
      refute shown =~ exempt.description
    end

    test "does not ask the model when nothing is open", %{scope: scope} do
      LLMStub.script([LLMStub.text()])

      assert MonthClose.run(scope, @month) == {:ok, %{proposed: 0, elorus_skipped?: false}}
      assert requests() == []
    end

    test "refuses an invoice that no tool returned", %{scope: scope} do
      transaction = transaction_fixture(scope)
      invoice = invoice_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([
          propose(transaction, %{"kind" => "attach", "invoice_id" => invoice.id})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(transaction) == nil

      assert [_first, second] = requests()
      assert [{%{"error" => _}, true}] = LLMStub.tool_results(second)
    end

    test "refuses the transaction of another user", %{scope: scope} do
      transaction_fixture(scope)
      other = transaction_fixture(user_scope_fixture())

      LLMStub.script([
        LLMStub.tool_use([
          {"find_invoices", %{"transaction_id" => other.id}},
          propose(other, %{"kind" => "no_invoice", "note" => "bank fee"})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(other) == nil

      assert [_first, second] = requests()
      assert [{%{"error" => _}, true}, {%{"error" => _}, true}] = LLMStub.tool_results(second)
    end

    test "refuses a proposal without a rationale, and a kind it does not know", %{scope: scope} do
      transaction = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([
          {"propose", %{"transaction_id" => transaction.id, "kind" => "no_invoice"}},
          propose(transaction, %{"kind" => "delete"})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(transaction) == nil
    end

    test "says it was not done when the model keeps asking for tools, and keeps what it found",
         %{scope: scope} do
      transaction = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([propose(transaction, %{"kind" => "no_invoice", "note" => "bank fee"})]),
        LLMStub.tool_use([{"find_invoices", %{"transaction_id" => transaction.id}}])
      ])

      assert MonthClose.run(scope, @month) == {:error, :too_many_steps}
      assert length(requests()) == 25
      assert %Proposal{} = proposal(transaction)
    end

    test "drops the proposal of a transaction that is settled by hand", %{scope: scope} do
      attached = transaction_fixture(scope)
      exempt = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([
          propose(attached, %{"kind" => "no_invoice"}),
          propose(exempt, %{"kind" => "no_invoice"})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 2}} = MonthClose.run(scope, @month)

      :ok = Invoicing.attach(scope, invoice_fixture(scope), attached)
      {:ok, _} = Banking.mark_no_invoice(scope, Banking.get_transaction!(scope, exempt.id), "tax")

      assert proposal(attached) == nil
      assert proposal(exempt) == nil
    end

    test "drops the proposals of the run before", %{scope: scope} do
      transaction = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([propose(transaction, %{"kind" => "no_invoice", "note" => "bank fee"})]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 1}} = MonthClose.run(scope, @month)
      assert %Proposal{kind: :no_invoice, note: "bank fee"} = proposal(transaction)

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(transaction) == nil
    end

    test "keeps one proposal per transaction, the last", %{scope: scope} do
      transaction = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([propose(transaction, %{"kind" => "no_invoice", "note" => "tax"})]),
        LLMStub.tool_use([propose(transaction, %{"kind" => "no_invoice", "note" => "bank fee"})]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 1}} = MonthClose.run(scope, @month)
      assert [%Proposal{note: "bank fee"}] = Repo.all(Proposal)
    end

    test "tells that the provider refused the key, and keeps what was proposed", %{scope: scope} do
      transaction = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([propose(transaction, %{"kind" => "no_invoice", "note" => "bank fee"})]),
        {401, %{"type" => "error", "error" => %{"type" => "authentication_error"}}}
      ])

      assert MonthClose.run(scope, @month) == {:error, :unauthorized}
      assert %Proposal{} = proposal(transaction)
    end

    test "does not call an answer that was cut off done", %{scope: scope} do
      transaction_fixture(scope)
      LLMStub.script([LLMStub.cut_off()])

      assert MonthClose.run(scope, @month) == {:error, :cut_off}
    end

    test "takes an id typed as text or as a float", %{scope: scope} do
      by_text = transaction_fixture(scope)
      by_float = transaction_fixture(scope)

      LLMStub.script([
        LLMStub.tool_use([
          propose(%{id: Integer.to_string(by_text.id)}, %{"kind" => "no_invoice"}),
          propose(%{id: by_float.id * 1.0}, %{"kind" => "no_invoice"})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 2}} = MonthClose.run(scope, @month)
      assert %Proposal{} = proposal(by_text)
      assert %Proposal{} = proposal(by_float)
    end

    test "leaves the proposals it did not replace when it fails", %{scope: scope} do
      transaction = transaction_fixture(scope)

      {:ok, _} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })

      LLMStub.script([
        {401, %{"type" => "error", "error" => %{"type" => "authentication_error"}}}
      ])

      assert MonthClose.run(scope, @month) == {:error, :unauthorized}
      assert %Proposal{} = proposal(transaction)
    end

    test "keeps a proposal to import from Elorus while Elorus is locked", %{scope: scope} do
      settings_fixture(scope)
      transaction = transaction_fixture(scope, %{"amount" => "100.00"})

      {:ok, _} =
        MonthClose.put_proposal(
          scope,
          transaction,
          %{elorus_invoice: ElorusStub.invoice_json()},
          %{
            "kind" => "import_elorus",
            "rationale" => "The amount and the client fit."
          }
        )

      LLMStub.script([LLMStub.text()])

      assert MonthClose.run(scope, @month) == {:ok, %{proposed: 0, elorus_skipped?: true}}
      assert %Proposal{kind: :import_elorus} = proposal(transaction)
    end

    test "refuses a second run of the month while one is going", %{scope: scope} do
      transaction_fixture(scope)
      LLMStub.script([LLMStub.text()])

      # The lock of the run that is going, which is held by its process
      lock = {{:month_close, scope.user.id, @month}, self()}
      second = fn -> Task.async(fn -> MonthClose.run(scope, @month) end) |> Task.await() end

      assert :global.trans(lock, second, [node()], 0) == {:error, :already_running}
      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
    end

    test "is off without a model", %{scope: scope} do
      settings = Application.fetch_env!(:ike_emails, MonthClose)
      on_exit(fn -> Application.put_env(:ike_emails, MonthClose, settings) end)
      Application.put_env(:ike_emails, MonthClose, model: nil)

      refute MonthClose.configured?()
      assert MonthClose.run(scope, @month) == {:error, :not_configured}
    end

    test "does not search Elorus while it is locked, and says so", %{scope: scope} do
      settings_fixture(scope)
      transaction_fixture(scope, %{"amount" => "100.00"})

      LLMStub.script([LLMStub.text()])
      assert MonthClose.run(scope, @month) == {:ok, %{proposed: 0, elorus_skipped?: true}}

      assert [%{"tools" => tools}] = requests()
      refute "search_elorus" in Enum.map(tools, & &1["name"])
    end
  end

  describe "run/2 with Elorus unlocked" do
    setup :configure_settings

    test "proposes an invoice of Elorus, which approving imports", %{scope: scope} do
      transaction = transaction_fixture(scope, %{"amount" => "100.00"})
      elorus = ElorusStub.invoice_json()
      ElorusStub.stub(invoices: [elorus])

      LLMStub.script([
        LLMStub.tool_use([{"search_elorus", %{"transaction_id" => transaction.id}}]),
        LLMStub.tool_use([
          propose(transaction, %{"kind" => "import_elorus", "elorus_id" => elorus["id"]})
        ]),
        LLMStub.text()
      ])

      assert MonthClose.run(scope, @month) == {:ok, %{proposed: 1, elorus_skipped?: false}}

      assert [first, second, _third] = requests()
      assert "search_elorus" in Enum.map(first["tools"], & &1["name"])

      assert [{[%{"same_amount" => true, "already_stored" => false}], false}] =
               LLMStub.tool_results(second)

      assert %Proposal{kind: :import_elorus, elorus_invoice: ^elorus} =
               proposal = proposal(transaction)

      assert Invoicing.list_invoices(scope) == []

      assert MonthClose.approve(scope, proposal) == :ok
      assert [invoice] = Banking.get_transaction!(scope, transaction.id).invoices
      assert invoice.elorus_id == elorus["id"]
      assert proposal(transaction) == nil
    end

    test "asks Elorus once for a month, whatever the number of transactions", %{scope: scope} do
      first = transaction_fixture(scope, %{"amount" => "100.00"})
      second = transaction_fixture(scope, %{"amount" => "100.00"})
      ElorusStub.stub(invoices: [ElorusStub.invoice_json()])

      LLMStub.script([
        LLMStub.tool_use([
          {"search_elorus", %{"transaction_id" => first.id}},
          {"search_elorus", %{"transaction_id" => second.id}}
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)

      assert [_first, answered] = requests()

      assert [{[%{"same_amount" => true}], false}, {[%{"same_amount" => true}], false}] =
               LLMStub.tool_results(answered)

      assert elorus_requests() == 1
    end

    test "asks for 3 months of Elorus at most", %{scope: scope} do
      transaction = transaction_fixture(scope, %{"amount" => "100.00"})
      ElorusStub.stub()

      months = ~w(2026-10 2026-09 2026-08 2026-07)

      LLMStub.script([
        LLMStub.tool_use(
          Enum.map(
            months,
            &{"search_elorus", %{"transaction_id" => transaction.id, "month" => &1}}
          )
        ),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)

      assert [_first, answered] = requests()

      assert [{_, false}, {_, false}, {_, false}, {%{"error" => _}, true}] =
               LLMStub.tool_results(answered)

      assert elorus_requests() == 3
    end

    test "does not ask again for a month that Elorus refused", %{scope: scope} do
      first = transaction_fixture(scope, %{"amount" => "100.00"})
      second = transaction_fixture(scope, %{"amount" => "100.00"})
      ElorusStub.stub(status: 429)

      LLMStub.script([
        LLMStub.tool_use([
          {"search_elorus", %{"transaction_id" => first.id}},
          {"search_elorus", %{"transaction_id" => second.id}}
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)

      assert [_first, answered] = requests()
      assert [{%{"error" => _}, true}, {%{"error" => _}, true}] = LLMStub.tool_results(answered)
      assert elorus_requests() == 1
    end

    test "drops a proposal to import from Elorus that it does not make again", %{scope: scope} do
      transaction = transaction_fixture(scope, %{"amount" => "100.00"})
      ElorusStub.stub()

      {:ok, _} =
        MonthClose.put_proposal(
          scope,
          transaction,
          %{elorus_invoice: ElorusStub.invoice_json()},
          %{
            "kind" => "import_elorus",
            "rationale" => "The amount and the client fit."
          }
        )

      LLMStub.script([LLMStub.text()])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(transaction) == nil
    end

    test "refuses an invoice of Elorus for a payment", %{scope: scope} do
      transaction_fixture(scope, %{"amount" => "100.00"})
      payment = transaction_fixture(scope)
      elorus = ElorusStub.invoice_json()
      ElorusStub.stub(invoices: [elorus])

      LLMStub.script([
        LLMStub.tool_use([{"search_elorus", %{"transaction_id" => payment.id}}]),
        LLMStub.tool_use([
          propose(payment, %{"kind" => "import_elorus", "elorus_id" => elorus["id"]})
        ]),
        LLMStub.text()
      ])

      assert {:ok, %{proposed: 0}} = MonthClose.run(scope, @month)
      assert proposal(payment) == nil
    end
  end

  describe "approve/2 and reject/2" do
    test "attach the invoice and drop the proposal", %{scope: scope} do
      transaction = transaction_fixture(scope)
      invoice = invoice_fixture(scope)

      {:ok, proposal} =
        MonthClose.put_proposal(scope, transaction, %{invoice_id: invoice.id}, %{
          "kind" => "attach",
          "rationale" => "It fits."
        })

      assert MonthClose.approve(scope, proposal) == :ok
      assert [%{id: id}] = Banking.get_transaction!(scope, transaction.id).invoices
      assert id == invoice.id
      assert proposal(transaction) == nil
    end

    test "mark the transaction as needing no invoice, with the reason", %{scope: scope} do
      transaction = transaction_fixture(scope)

      {:ok, proposal} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "note" => "bank fee",
          "rationale" => "It is a commission of the bank."
        })

      assert MonthClose.approve(scope, proposal) == :ok

      assert %{no_invoice: true, no_invoice_note: "bank fee"} =
               Banking.get_transaction!(scope, transaction.id)

      assert proposal(transaction) == nil
    end

    test "refuse a proposal that an invoice settled meanwhile, which is dropped", %{scope: scope} do
      transaction = transaction_fixture(scope)

      {:ok, proposal} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })

      invoice_fixture(scope, %{}, transaction_ids: [transaction.id])
      assert proposal(transaction) == nil

      # A page that still shows the proposal sends it
      assert MonthClose.approve(scope, proposal) == {:error, :has_invoices}
      refute Banking.get_transaction!(scope, transaction.id).no_invoice
    end

    test "a replacing proposal has an id of its own, so a stale approval finds nothing", %{
      scope: scope
    } do
      transaction = transaction_fixture(scope)

      {:ok, first} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })

      {:ok, second} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "note" => "tax",
          "rationale" => "It is a tax."
        })

      refute second.id == first.id
      assert MonthClose.get_proposal(scope, first.id) == nil
      assert proposal(transaction).id == second.id
    end

    test "reject drops the proposal and changes nothing, twice as well", %{scope: scope} do
      transaction = transaction_fixture(scope)

      {:ok, proposal} =
        MonthClose.put_proposal(scope, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })

      assert MonthClose.reject(scope, proposal) == :ok
      assert MonthClose.reject(scope, proposal) == :ok
      assert proposal(transaction) == nil
      refute Banking.get_transaction!(scope, transaction.id).no_invoice
    end
  end
end
