defmodule SymphonyElixir.DuetGithubReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.GithubReview

  defp review(reviewer, state, opts \\ []) do
    base = %{
      "id" => Keyword.get(opts, :id, System.unique_integer([:positive])),
      "user" => %{"login" => reviewer, "id" => 1, "type" => "Bot"},
      "state" => state,
      "commit_id" => Keyword.get(opts, :commit_id, "abc123"),
      "submitted_at" => Keyword.get(opts, :submitted_at, "2026-05-10T14:00:00Z"),
      "body" => Keyword.get(opts, :body, "")
    }

    Enum.reduce(Keyword.get(opts, :overrides, []), base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  describe "parse_reviews/1" do
    test "returns [] for an empty list" do
      assert GithubReview.parse_reviews([]) == []
    end

    test "parses a single APPROVED review with all fields populated" do
      input = [
        %{
          "id" => 12_345,
          "user" => %{"login" => "claude-bot", "id" => 9876, "type" => "Bot"},
          "state" => "APPROVED",
          "commit_id" => "abc123def456",
          "submitted_at" => "2026-05-10T14:00:00Z",
          "body" => "LGTM"
        }
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.id == 12_345
      assert parsed.reviewer == "claude-bot"
      assert parsed.state == "APPROVED"
      assert parsed.commit_id == "abc123def456"
      assert parsed.body == "LGTM"
      assert %DateTime{} = parsed.submitted_at
      assert DateTime.to_iso8601(parsed.submitted_at) == "2026-05-10T14:00:00Z"
    end

    test "skips entries with user: nil" do
      input = [
        %{"id" => 1, "user" => nil, "state" => "APPROVED", "commit_id" => "abc"},
        review("claude-bot", "APPROVED", id: 2)
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.id == 2
      assert parsed.reviewer == "claude-bot"
    end

    test "skips entries with no user key at all" do
      input = [
        %{"id" => 1, "state" => "APPROVED", "commit_id" => "abc"},
        review("codex-bot", "CHANGES_REQUESTED", id: 2)
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.reviewer == "codex-bot"
    end

    test "skips entries where user.login is missing or not a binary" do
      input = [
        %{"id" => 1, "user" => %{"id" => 9876}, "state" => "APPROVED"},
        %{"id" => 2, "user" => %{"login" => 42}, "state" => "APPROVED"},
        review("claude-bot", "APPROVED", id: 3)
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.id == 3
    end

    test "skips entries with no state" do
      input = [
        %{
          "id" => 1,
          "user" => %{"login" => "claude-bot"},
          "commit_id" => "abc"
        },
        review("codex-bot", "APPROVED", id: 2)
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.reviewer == "codex-bot"
    end

    test "skips entries with non-binary state" do
      input = [
        %{
          "id" => 1,
          "user" => %{"login" => "claude-bot"},
          "state" => :approved
        },
        review("codex-bot", "APPROVED", id: 2)
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.reviewer == "codex-bot"
    end

    test "leaves submitted_at nil when the timestamp is unparseable" do
      input = [review("claude-bot", "APPROVED", submitted_at: "not-a-real-timestamp")]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.reviewer == "claude-bot"
      assert parsed.submitted_at == nil
    end

    test "leaves submitted_at nil when the field is missing" do
      input = [
        %{
          "id" => 1,
          "user" => %{"login" => "claude-bot"},
          "state" => "APPROVED",
          "commit_id" => "abc"
        }
      ]

      assert [parsed] = GithubReview.parse_reviews(input)
      assert parsed.submitted_at == nil
    end

    test "preserves input order" do
      input = [
        review("claude-bot", "APPROVED", id: 1),
        review("codex-bot", "CHANGES_REQUESTED", id: 2),
        review("claude-bot", "COMMENTED", id: 3)
      ]

      assert [first, second, third] = GithubReview.parse_reviews(input)
      assert first.id == 1
      assert second.id == 2
      assert third.id == 3
      assert first.state == "APPROVED"
      assert second.state == "CHANGES_REQUESTED"
      assert third.state == "COMMENTED"
    end

    test "handles a multi-review array of three entries with mixed states" do
      input = [
        review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
        review("codex-bot", "DISMISSED", id: 2, submitted_at: "2026-05-10T14:05:00Z"),
        review("claude-bot", "CHANGES_REQUESTED", id: 3, submitted_at: "2026-05-10T14:10:00Z")
      ]

      parsed = GithubReview.parse_reviews(input)
      assert length(parsed) == 3

      assert Enum.map(parsed, & &1.state) == ["APPROVED", "DISMISSED", "CHANGES_REQUESTED"]
      assert Enum.map(parsed, & &1.reviewer) == ["claude-bot", "codex-bot", "claude-bot"]
    end

    test "rejects atom-keyed maps with an ArgumentError" do
      input = [
        %{
          id: 1,
          user: %{"login" => "claude-bot"},
          state: "APPROVED"
        }
      ]

      assert_raise ArgumentError, ~r/string-keyed maps/, fn ->
        GithubReview.parse_reviews(input)
      end
    end
  end

  describe "latest_per_reviewer/1" do
    test "returns %{} for an empty list" do
      assert GithubReview.latest_per_reviewer([]) == %{}
    end

    test "returns one entry for a single APPROVED review" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "APPROVED")])

      assert GithubReview.latest_per_reviewer([parsed]) == %{"claude-bot" => parsed}
    end

    test "keeps both reviewers when each has one APPROVED review" do
      [claude_review, codex_review] =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1),
          review("codex-bot", "APPROVED", id: 2)
        ])

      result = GithubReview.latest_per_reviewer([claude_review, codex_review])

      assert result == %{"claude-bot" => claude_review, "codex-bot" => codex_review}
    end

    test "keeps the later CHANGES_REQUESTED when same reviewer flips from APPROVED" do
      [first, second] =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
          review("claude-bot", "CHANGES_REQUESTED", id: 2, submitted_at: "2026-05-10T14:05:00Z")
        ])

      result = GithubReview.latest_per_reviewer([first, second])

      assert result == %{"claude-bot" => second}
      assert result["claude-bot"].state == "CHANGES_REQUESTED"
    end

    test "DISMISSED after APPROVED removes the reviewer entirely" do
      [first, second] =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
          review("claude-bot", "DISMISSED", id: 2, submitted_at: "2026-05-10T14:05:00Z")
        ])

      assert GithubReview.latest_per_reviewer([first, second]) == %{}
    end

    test "COMMENTED-only is not binding and produces no entry" do
      reviews = GithubReview.parse_reviews([review("claude-bot", "COMMENTED")])

      assert GithubReview.latest_per_reviewer(reviews) == %{}
    end

    test "mixed three-reviewer flow keeps only the surviving non-dismissed signals" do
      reviews =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
          review("codex-bot", "CHANGES_REQUESTED", id: 2, submitted_at: "2026-05-10T14:05:00Z"),
          review("claude-bot", "DISMISSED", id: 3, submitted_at: "2026-05-10T14:10:00Z")
        ])

      result = GithubReview.latest_per_reviewer(reviews)

      assert Map.keys(result) == ["codex-bot"]
      assert result["codex-bot"].state == "CHANGES_REQUESTED"
      assert result["codex-bot"].id == 2
    end

    test "with equal timestamps the later list position wins" do
      [first, second] =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
          review("claude-bot", "CHANGES_REQUESTED", id: 2, submitted_at: "2026-05-10T14:00:00Z")
        ])

      result = GithubReview.latest_per_reviewer([first, second])

      assert result["claude-bot"] == second
    end

    test "DISMISSED before any binding review for that reviewer is a no-op" do
      reviews =
        GithubReview.parse_reviews([
          review("claude-bot", "DISMISSED", id: 1),
          review("codex-bot", "APPROVED", id: 2)
        ])

      result = GithubReview.latest_per_reviewer(reviews)

      assert Map.keys(result) == ["codex-bot"]
    end

    test "ignores COMMENTED entries between binding reviews" do
      reviews =
        GithubReview.parse_reviews([
          review("claude-bot", "APPROVED", id: 1, submitted_at: "2026-05-10T14:00:00Z"),
          review("claude-bot", "COMMENTED", id: 2, submitted_at: "2026-05-10T14:05:00Z")
        ])

      result = GithubReview.latest_per_reviewer(reviews)

      assert result["claude-bot"].id == 1
      assert result["claude-bot"].state == "APPROVED"
    end
  end

  describe "binding_state/1" do
    test "maps an APPROVED struct to :approve" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "APPROVED")])
      assert GithubReview.binding_state(parsed) == :approve
    end

    test "maps a CHANGES_REQUESTED struct to :request_changes" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "CHANGES_REQUESTED")])
      assert GithubReview.binding_state(parsed) == :request_changes
    end

    test "maps a DISMISSED struct to :other" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "DISMISSED")])
      assert GithubReview.binding_state(parsed) == :other
    end

    test "maps a COMMENTED struct to :other" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "COMMENTED")])
      assert GithubReview.binding_state(parsed) == :other
    end

    test "maps a PENDING struct to :other" do
      [parsed] = GithubReview.parse_reviews([review("claude-bot", "PENDING")])
      assert GithubReview.binding_state(parsed) == :other
    end

    test "maps the raw string \"APPROVED\" to :approve" do
      assert GithubReview.binding_state("APPROVED") == :approve
    end

    test "maps the raw string \"CHANGES_REQUESTED\" to :request_changes" do
      assert GithubReview.binding_state("CHANGES_REQUESTED") == :request_changes
    end

    test "is strict about casing — \"approved\" maps to :other" do
      assert GithubReview.binding_state("approved") == :other
    end

    test "maps an unknown state string to :other" do
      assert GithubReview.binding_state("WAT") == :other
    end

    test "maps the empty string to :other" do
      assert GithubReview.binding_state("") == :other
    end
  end

  describe "binding_states/0" do
    test ~S(returns exactly ["APPROVED", "CHANGES_REQUESTED"]) do
      assert GithubReview.binding_states() == ["APPROVED", "CHANGES_REQUESTED"]
    end
  end
end
