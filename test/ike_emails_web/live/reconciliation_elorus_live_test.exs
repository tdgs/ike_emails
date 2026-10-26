defmodule IkeEmailsWeb.ReconciliationElorusLiveTest do
  # Not async: the Elorus stub is shared with the tasks that call it, and some
  # tests change the settings
  use IkeEmailsWeb.ConnCase, async: false

  import IkeEmails.ElorusStub
  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.Banking
  alias IkeEmails.Elorus
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Repo

  # The tasks that call Elorus, and the failures they cause, are logged
  @moduletag :capture_log

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    elorus = Application.fetch_env!(:ike_emails, Elorus)
    business = Application.fetch_env!(:ike_emails, :business)

    on_exit(fn ->
      Application.put_env(:ike_emails, Elorus, elorus)
      Application.put_env(:ike_emails, :business, business)
    end)
  end

  defp income(attrs \\ %{}), do: transaction_fixture(Map.merge(%{"amount" => "100.00"}, attrs))

  defp panel(transaction, month \\ "2026-10"),
    do: ~p"/transactions/#{transaction.id}/invoice?month=#{month}"

  defp elorus_row(id), do: "#elorus_invoices-#{id}"

  # The results arrive from a task, after the click
  defp wait_for(view, selector, tries \\ 100) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} did not show up")
      true -> Process.sleep(10) && wait_for(view, selector, tries - 1)
    end
  end

  defp search(view) do
    view |> element("#search-elorus") |> render_click()
  end

  defp listed_ids(view) do
    view
    |> element("#elorus-invoices")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^=elorus_invoices-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "elorus_invoices-", ""))
  end

  describe "the section" do
    test "is there for money in, with a button, and asks nothing yet", %{conn: conn} do
      stub()
      {:ok, view, _html} = live(conn, panel(income()))

      assert has_element?(view, "#elorus-section")
      assert has_element?(view, "#search-elorus", "October 2026")
      refute has_element?(view, "#elorus-invoices")
      refute_receive {:elorus_request, _}, 200
    end

    test "is not there for money out", %{conn: conn} do
      {:ok, view, _html} = live(conn, panel(transaction_fixture(%{"amount" => "-100.00"})))

      assert has_element?(view, "#attach-panel")
      refute has_element?(view, "#elorus-section")
    end

    test "tells how to set Elorus up when it is not", %{conn: conn} do
      stub(invoices: [invoice_json()])
      config = Application.fetch_env!(:ike_emails, Elorus)
      Application.put_env(:ike_emails, Elorus, Keyword.put(config, :api_token, nil))

      {:ok, view, _html} = live(conn, panel(income()))

      assert has_element?(view, "#elorus-unconfigured")
      refute has_element?(view, "#search-elorus")

      render_hook(view, "search_elorus", %{})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
      refute has_element?(view, "#elorus-invoices")
    end
  end

  describe "searching" do
    test "lists the invoices of the month, the ones for the amount first", %{conn: conn} do
      stub(
        invoices: [
          invoice_json(%{"id" => "a", "total" => "30.00", "payable" => "30.00"}),
          invoice_json(%{"id" => "b", "total" => "100.00", "payable" => "100.00"}),
          invoice_json(%{"id" => "c", "total" => "50.00", "payable" => "50.00"}),
          invoice_json(%{"id" => "d", "total" => "125.00", "payable" => "100.00"})
        ]
      )

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)
      wait_for(view, "#elorus-invoices")

      assert listed_ids(view) == ["b", "d", "a", "c"]
      assert has_element?(view, elorus_row("b"), "same amount")
      assert has_element?(view, elorus_row("d"), "same amount")
      refute has_element?(view, elorus_row("a"), "same amount")
      assert has_element?(view, elorus_row("a"), "Acme Inc.")
      assert has_element?(view, elorus_row("a"), "30,00 €")
      assert has_element?(view, "#{elorus_row("a")} a[href='https://app.elorus.com/p/abc/']")
      assert has_element?(view, "#attach-elorus-a")
    end

    test "asks for the month that is shown, not the one of the transaction", %{conn: conn} do
      stub()
      transaction = income(%{"date" => "2026-09-14"})

      {:ok, view, _html} = live(conn, panel(transaction, "2026-08"))
      assert has_element?(view, "#search-elorus", "August 2026")
      search(view)
      wait_for(view, "#elorus-empty")

      assert %{"period_from" => "2026-08-01", "period_to" => "2026-08-31"} = last_query()
    end

    test "says so when the month has no invoices", %{conn: conn} do
      stub(invoices: [])

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)

      wait_for(view, "#elorus-empty")
      assert has_element?(view, "#elorus-empty", "October 2026")
    end

    test "marks the invoices that were imported", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"}), invoice_json(%{"id" => "b"})])

      {:ok, _} =
        Invoicing.import_elorus_invoice(
          Elorus.Invoice.from_api(invoice_json(%{"id" => "b"})),
          income()
        )

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)
      wait_for(view, elorus_row("a"))

      refute has_element?(view, elorus_row("a"), "stored")
      assert has_element?(view, elorus_row("b"), "stored")
    end

    for {status, message} <- [
          {401, "refused the API key"},
          {403, "refused the API key"},
          {429, "limiting requests"},
          {500, "unexpected status (500)"}
        ] do
      test "shows the failure when Elorus answers #{status}", %{conn: conn} do
        stub(status: unquote(status))

        {:ok, view, _html} = live(conn, panel(income()))
        search(view)

        wait_for(view, "#elorus-error")
        assert has_element?(view, "#elorus-error", unquote(message))
        refute has_element?(view, "#elorus-invoices")
        assert has_element?(view, "#search-elorus:not([disabled])")
      end
    end

    test "can be tried again after a failure", %{conn: conn} do
      stub(status: 500)
      {:ok, view, _html} = live(conn, panel(income()))
      search(view)
      wait_for(view, "#elorus-error")

      stub(invoices: [invoice_json(%{"id" => "a"})])
      search(view)
      wait_for(view, elorus_row("a"))

      refute has_element?(view, "#elorus-error")
    end

    test "shows a crashed task as a failure", %{conn: conn} do
      Req.Test.stub(Elorus, fn _conn -> raise "boom" end)

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Something went wrong with Elorus")
      assert has_element?(view, "#search-elorus:not([disabled])")
    end

    test "shows a failed connection as such", %{conn: conn} do
      Req.Test.stub(Elorus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Could not reach Elorus")
    end

    test "tells how long to wait when Elorus limits the requests", %{conn: conn} do
      Req.Test.stub(Elorus, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.send_resp(429, "")
      end)

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Try again in 42 seconds")
    end

    test "runs one task at a time, and forgets the one of a closed panel", %{conn: conn} do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        send(test, {:blocked, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :timeout
        end

        Req.Test.json(conn, %{
          "count" => 1,
          "next" => nil,
          "previous" => nil,
          "results" => [invoice_json(%{"id" => "late"})]
        })
      end)

      transaction = income()
      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      assert_receive {:blocked, task}, 1_000

      assert has_element?(view, "#search-elorus[disabled]", "Searching")
      render_hook(view, "search_elorus", %{})
      refute_receive {:blocked, _other}, 100

      # The panel is closed, and opened again, before the answer comes
      render_patch(view, ~p"/?month=2026-10")
      render_patch(view, panel(transaction))

      ref = Process.monitor(task)
      send(task, :release)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert has_element?(view, "#search-elorus:not([disabled])")
      refute has_element?(view, "#elorus-invoices")
      refute has_element?(view, elorus_row("late"))
    end
  end

  describe "attaching" do
    test "stores the invoice with its PDF, attaches it and closes the panel", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a", "total" => "100.00"})])
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")

      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 1_000)

      assert has_element?(view, "#flash-info", "Invoice attached from Elorus")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      refute has_element?(view, "#attach-panel")

      assert [%Invoice{elorus_id: "a", amount_cents: 10_000, receiver_name: "Acme Inc."}] =
               Banking.get_transaction!(transaction.id).invoices
    end

    test "does not download again an invoice that was imported", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})])

      {:ok, _} =
        Invoicing.import_elorus_invoice(
          Elorus.Invoice.from_api(invoice_json(%{"id" => "a"})),
          income()
        )

      request_paths()

      transaction = income()
      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 1_000)

      assert request_paths() == ["/v1.2/invoices/"]
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert Repo.aggregate(Invoice, :count) == 1
    end

    test "shows why when the PDF cannot be downloaded", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})], pdf_status: 404)
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "does not have that invoice")
      assert has_element?(view, "#attach-panel")
      assert has_element?(view, elorus_row("a"))
      assert Banking.get_transaction!(transaction.id).invoices == []
    end

    test "says when the business has no name", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      Application.put_env(:ike_emails, :business, [])

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "BUSINESS_NAME")
    end

    test "says what is wrong with an invoice that cannot be stored", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a", "total" => "99999999999.00"})])

      {:ok, view, _html} = live(conn, panel(income()))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "amount input is too large")
    end

    test "ignores an id that was not listed", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      request_paths()

      render_hook(view, "attach_elorus", %{"id" => "not-listed"})
      render_hook(view, "attach_elorus", %{"id" => "../../x"})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
      assert Banking.get_transaction!(transaction.id).invoices == []
    end

    test "is not possible for money out", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = transaction_fixture(%{"amount" => "-100.00"})

      {:ok, view, _html} = live(conn, panel(transaction))
      render_hook(view, "search_elorus", %{})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
    end
  end

  describe "an import that takes a while" do
    # Lists one invoice at once, and holds the download of its PDF until released
    defp stub_slow_pdf(pdf_status \\ 200) do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        case String.split(conn.request_path, "/", trim: true) do
          ["v1.2", "invoices"] ->
            send(test, {:elorus_request, conn})

            Req.Test.json(conn, %{
              "count" => 1,
              "next" => nil,
              "previous" => nil,
              "results" => [invoice_json(%{"id" => "a"})]
            })

          ["v1.2", "invoices", "a", "pdf"] ->
            send(test, {:elorus_request, conn})
            send(test, {:blocked, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :timeout
            end

            if pdf_status == 200 do
              conn
              |> Plug.Conn.put_resp_content_type("application/pdf")
              |> Plug.Conn.send_resp(200, pdf("a"))
            else
              Plug.Conn.send_resp(conn, pdf_status, "")
            end
        end
      end)
    end

    defp release(task) do
      ref = Process.monitor(task)
      send(task, :release)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 1_000
    end

    test "shows that it runs, and keeps the buttons from being used", %{conn: conn} do
      stub_slow_pdf()
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      refute has_element?(view, "#elorus-invoices[data-busy]")

      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 1_000

      assert has_element?(view, "#elorus-invoices[data-busy]")
      assert has_element?(view, "#elorus-importing")
      assert has_element?(view, "#search-elorus[disabled]")

      # A second click is ignored
      render_hook(view, "attach_elorus", %{"id" => "a"})
      refute_receive {:blocked, _other}, 100

      release(task)
      assert_patch(view, ~p"/?month=2026-10", 1_000)
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
    end

    test "goes on when the panel is closed, and brings the rows up to date", %{conn: conn} do
      stub_slow_pdf()
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 1_000

      render_patch(view, ~p"/?month=2026-10")
      assert has_element?(view, "#status-#{transaction.id}[data-status=income]")

      # Neither a search nor a second import can start meanwhile, even if the
      # panel of the transaction is opened again
      render_patch(view, panel(transaction))
      render_hook(view, "search_elorus", %{})
      assert has_element?(view, "#search-elorus[disabled]")

      release(task)
      wait_for(view, "#flash-info")

      assert has_element?(view, "#flash-info", "Invoice attached from Elorus")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert Repo.aggregate(Invoice, :count) == 1
      assert request_paths() == ["/v1.2/invoices/", "/v1.2/invoices/a/pdf/"]
    end

    test "reports a failure with a message when the panel was closed", %{conn: conn} do
      stub_slow_pdf(404)
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 1_000

      render_patch(view, ~p"/?month=2026-10")
      release(task)
      wait_for(view, "#flash-error")

      assert has_element?(view, "#flash-error", "was not attached")
      assert has_element?(view, "#flash-error", "does not have that invoice")
      assert has_element?(view, "#status-#{transaction.id}[data-status=income]")
    end
  end

  describe "the receiver" do
    test "shows in the invoice that was attached", %{conn: conn} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = income()

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 1_000)

      assert [%Invoice{id: id}] = Banking.get_transaction!(transaction.id).invoices

      assert has_element?(
               view,
               "#transactions-#{transaction.id}-invoice-#{id}",
               "Test Business"
             )

      assert has_element?(view, "#transactions-#{transaction.id}-invoice-#{id}", "Acme Inc.")
    end
  end
end
