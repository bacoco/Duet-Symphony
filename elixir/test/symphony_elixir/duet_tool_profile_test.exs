defmodule SymphonyElixir.DuetToolProfileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.ToolProfile

  @strict_review_yaml_example %{
    "enabled" => true,
    "default_profile" => "strict_review",
    "profiles" => %{
      "default" => %{
        "spec" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
        "plan" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
        "code" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
        "review" => %{"coder_ack" => "all", "reviewer" => "all"}
      },
      "strict_review" => %{
        "spec" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
        "plan" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
        "code" => %{
          "author" => ["file_write", "git_push", "shell"],
          "reviewers" => %{
            "default" => ["file_read", "git_diff", "shell_readonly"],
            "claude" => ["file_read", "git_diff", "shell_readonly", "web_search"]
          }
        },
        "review" => %{
          "coder_ack" => ["file_read", "git_diff"],
          "reviewer" => ["file_read", "git_diff", "shell_readonly", "web_search"]
        }
      }
    }
  }

  describe "known_tools/0" do
    test "returns the documented tool identifier list" do
      assert ToolProfile.known_tools() ==
               ~w(file_read file_write git_diff git_push shell shell_readonly web_search)
    end
  end

  describe "enabled?/1" do
    test "empty map is disabled" do
      assert ToolProfile.enabled?(%{}) == false
    end

    test "string-key enabled flag" do
      assert ToolProfile.enabled?(%{"enabled" => true}) == true
      assert ToolProfile.enabled?(%{"enabled" => false}) == false
    end

    test "atom-key enabled flag is normalized" do
      assert ToolProfile.enabled?(%{enabled: true}) == true
      assert ToolProfile.enabled?(%{enabled: false}) == false
    end
  end

  describe "default_profile_name/1" do
    test "defaults to \"default\" when absent" do
      assert ToolProfile.default_profile_name(%{}) == "default"
    end

    test "returns the configured default_profile name" do
      assert ToolProfile.default_profile_name(%{"default_profile" => "strict_review"}) == "strict_review"
    end

    test "supports atom keys" do
      assert ToolProfile.default_profile_name(%{default_profile: "strict_review"}) == "strict_review"
    end
  end

  describe "resolve/4" do
    test "feature disabled returns :all regardless of profile/phase/role" do
      config = %{"enabled" => false, "profiles" => %{}}
      assert {:ok, :all} = ToolProfile.resolve(config, "anything", "code", "author")
      assert {:ok, :all} = ToolProfile.resolve(config, "missing", "review", "coder_ack")
    end

    test "feature enabled but profile not declared returns :unknown_profile" do
      config = %{"enabled" => true, "profiles" => %{}}

      assert {:error, {:unknown_profile, "missing"}} =
               ToolProfile.resolve(config, "missing", "code", "author")
    end

    test "explicit \"all\" string value resolves to :all" do
      assert {:ok, :all} =
               ToolProfile.resolve(@strict_review_yaml_example, "default", "code", "author")
    end

    test "atom :all value resolves to :all" do
      config = %{
        "enabled" => true,
        "profiles" => %{
          "p" => %{"code" => %{"author" => :all, "reviewers" => %{"default" => "all"}}}
        }
      }

      assert {:ok, :all} = ToolProfile.resolve(config, "p", "code", "author")
    end

    test "missing phase entry resolves to :all (no constraint declared)" do
      config = %{
        "enabled" => true,
        "profiles" => %{"p" => %{}}
      }

      assert {:ok, :all} = ToolProfile.resolve(config, "p", "code", "author")
      assert {:ok, :all} = ToolProfile.resolve(config, "p", "review", "coder_ack")
    end

    test "missing role entry within a declared phase resolves to :all" do
      config = %{
        "enabled" => true,
        "profiles" => %{
          "p" => %{"code" => %{"author" => ["file_write"]}}
        }
      }

      assert {:ok, :all} = ToolProfile.resolve(config, "p", "code", "reviewer")
    end

    test "code/author with explicit list returns sorted list" do
      assert {:ok, ["file_write", "git_push", "shell"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "code", "author")
    end

    test "code/reviewer with explicit list returns sorted list" do
      assert {:ok, ["file_read", "git_diff", "shell_readonly"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "code", "reviewer")
    end

    test "code/reviewer supports actor-specific reviewer overrides" do
      assert {:ok, ["file_read", "git_diff", "shell_readonly", "web_search"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "code", "reviewer", "claude")
    end

    test "review/coder_ack with explicit list returns sorted list" do
      assert {:ok, ["file_read", "git_diff"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "review", "coder_ack")
    end

    test "review/reviewer with explicit list returns sorted list" do
      assert {:ok, ["file_read", "git_diff", "shell_readonly", "web_search"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "review", "reviewer")
    end

    test "list values are deduped and sorted" do
      config = %{
        "enabled" => true,
        "profiles" => %{
          "p" => %{
            "code" => %{
              "author" => ["shell", "file_write", "shell", "git_push"],
              "reviewers" => %{"default" => "all"}
            }
          }
        }
      }

      assert {:ok, ["file_write", "git_push", "shell"]} =
               ToolProfile.resolve(config, "p", "code", "author")
    end

    test "review with role \"author\" returns invalid_role error" do
      assert {:error, {:invalid_role, "strict_review", "review", "author"}} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "review", "author")
    end

    test "code with role \"coder_ack\" returns invalid_role error" do
      assert {:error, {:invalid_role, "strict_review", "code", "coder_ack"}} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "code", "coder_ack")
    end

    test "spec/plan with role \"coder_ack\" returns invalid_role error" do
      assert {:error, {:invalid_role, "strict_review", "spec", "coder_ack"}} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "spec", "coder_ack")

      assert {:error, {:invalid_role, "strict_review", "plan", "coder_ack"}} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "plan", "coder_ack")
    end

    test "unknown tool in list returns unknown_tool error" do
      config = %{
        "enabled" => true,
        "profiles" => %{
          "p" => %{
            "code" => %{
              "author" => ["file_write", "rocket_launcher"],
              "reviewers" => %{"default" => "all"}
            }
          }
        }
      }

      assert {:error, {:unknown_tool, "p", "code", "author", "rocket_launcher"}} =
               ToolProfile.resolve(config, "p", "code", "author")
    end

    test "phase outside the canonical list returns invalid_phase error" do
      config = %{
        "enabled" => true,
        "profiles" => %{"p" => %{}}
      }

      assert {:error, {:invalid_phase, "deploy"}} =
               ToolProfile.resolve(config, "p", "deploy", "author")
    end

    test "uppercase phase strings are accepted (lowercased)" do
      assert {:ok, ["file_write", "git_push", "shell"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", "CODE", "author")
    end

    test "atom phase/role are stringified and lowercased" do
      assert {:ok, ["file_write", "git_push", "shell"]} =
               ToolProfile.resolve(@strict_review_yaml_example, "strict_review", :code, :author)
    end

    test "atom-key config nested input still resolves correctly" do
      atom_config = %{
        enabled: true,
        default_profile: "p",
        profiles: %{
          p: %{
            code: %{author: ["file_write", "git_push"], reviewers: %{default: "all"}},
            review: %{coder_ack: :all, reviewer: ["file_read"]}
          }
        }
      }

      assert {:ok, ["file_write", "git_push"]} =
               ToolProfile.resolve(atom_config, "p", "code", "author")

      assert {:ok, :all} = ToolProfile.resolve(atom_config, "p", "code", "reviewer")
      assert {:ok, :all} = ToolProfile.resolve(atom_config, "p", "review", "coder_ack")
      assert {:ok, ["file_read"]} = ToolProfile.resolve(atom_config, "p", "review", "reviewer")
    end
  end

  describe "allows?/5" do
    test "returns true for any tool when resolve is :all" do
      config = %{"enabled" => false}
      assert ToolProfile.allows?(config, "any", "code", "author", "file_write")
      assert ToolProfile.allows?(config, "any", "code", "author", "rocket_launcher")
    end

    test "returns true when the tool is in the resolved list" do
      assert ToolProfile.allows?(
               @strict_review_yaml_example,
               "strict_review",
               "code",
               "author",
               "file_write"
             )
    end

    test "returns false when the tool is not in the resolved list" do
      refute ToolProfile.allows?(
               @strict_review_yaml_example,
               "strict_review",
               "code",
               "author",
               "file_read"
             )
    end

    test "returns false when resolve returns an error" do
      refute ToolProfile.allows?(
               @strict_review_yaml_example,
               "strict_review",
               "review",
               "author",
               "file_read"
             )

      refute ToolProfile.allows?(
               %{"enabled" => true, "profiles" => %{}},
               "missing",
               "code",
               "author",
               "file_read"
             )
    end
  end

  describe "validate_config/1" do
    test "empty map is :ok" do
      assert :ok = ToolProfile.validate_config(%{})
    end

    test "enabled non-boolean is rejected" do
      assert {:error, msg} = ToolProfile.validate_config(%{"enabled" => "yes"})
      assert msg =~ "tool_profiles.enabled"
      assert msg =~ "boolean"
    end

    test "default_profile non-binary is rejected" do
      assert {:error, msg} = ToolProfile.validate_config(%{"default_profile" => 42})
      assert msg =~ "tool_profiles.default_profile"
      assert msg =~ "string"
    end

    test "default_profile not in profiles is rejected when enabled" do
      config = %{
        "enabled" => true,
        "default_profile" => "missing",
        "profiles" => %{"default" => %{}}
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "default_profile"
      assert msg =~ "missing"
    end

    test "implicit default_profile is rejected when enabled and default profile is absent" do
      config = %{
        "enabled" => true,
        "profiles" => %{"strict_review" => %{}}
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "default_profile"
      assert msg =~ "default"
    end

    test "default_profile missing-from-profiles is tolerated when feature is disabled" do
      config = %{
        "enabled" => false,
        "default_profile" => "missing",
        "profiles" => %{"default" => %{}}
      }

      assert :ok = ToolProfile.validate_config(config)
    end

    test "profile with unknown phase key is rejected" do
      config = %{
        "profiles" => %{
          "p" => %{"deploy" => %{"author" => "all", "reviewers" => %{"default" => "all"}}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "tool_profiles.profiles.p"
      assert msg =~ "deploy"
    end

    test "phase with unknown role is rejected" do
      config = %{
        "profiles" => %{
          "p" => %{"code" => %{"coder_ack" => "all"}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "tool_profiles.profiles.p.code"
      assert msg =~ "coder_ack"
    end

    test "review phase with role \"author\" is rejected" do
      config = %{
        "profiles" => %{
          "p" => %{"review" => %{"author" => "all"}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "tool_profiles.profiles.p.review"
      assert msg =~ "author"
    end

    test "role value with unknown tool is rejected" do
      config = %{
        "profiles" => %{
          "p" => %{
            "code" => %{
              "author" => ["file_write", "rocket_launcher"],
              "reviewers" => %{"default" => "all"}
            }
          }
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "rocket_launcher"
    end

    test "role value that is neither \"all\" nor a list is rejected" do
      config = %{
        "profiles" => %{
          "p" => %{"code" => %{"author" => 42, "reviewers" => %{"default" => "all"}}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "tool_profiles.profiles.p.code.author"
    end

    test "empty tool lists are rejected" do
      config = %{
        "profiles" => %{
          "p" => %{"code" => %{"author" => [], "reviewers" => %{"default" => "all"}}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "must not be an empty tool list"
    end

    test "code phases must use reviewers map rather than direct reviewer role" do
      config = %{
        "profiles" => %{
          "p" => %{"code" => %{"author" => "all", "reviewer" => "all"}}
        }
      }

      assert {:error, msg} = ToolProfile.validate_config(config)
      assert msg =~ "unknown key"
      assert msg =~ "reviewer"
    end

    test "complete strict_review profile per the §7.8 YAML example is :ok" do
      assert :ok = ToolProfile.validate_config(@strict_review_yaml_example)
    end

    test "non-map config is rejected" do
      assert {:error, "tool_profiles must be a map"} = ToolProfile.validate_config(:not_a_map)
    end
  end
end
