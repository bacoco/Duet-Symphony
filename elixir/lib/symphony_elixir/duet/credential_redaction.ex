defmodule SymphonyElixir.Duet.CredentialRedaction do
  @moduledoc """
  Pure regex-based redactor for known credential patterns per spec §14.

  Recognized patterns and their replacement tokens:

  - **AWS access key IDs**: `AKIA[A-Z0-9]{16}` → `[REDACTED:aws_access_key]`
  - **AWS secret-style suspect**: a 40-char base64 alphabet token following
    `aws_secret`, `secret_access_key`, or similar → `[REDACTED:aws_secret]`
  - **PEM blocks**: `-----BEGIN <KIND>-----...-----END <KIND>-----`
    (multi-line) → `[REDACTED:pem_<kind>]`
  - **GitHub tokens**: `ghp_[A-Za-z0-9]{36,}`, `gho_...`, `ghs_...`,
    `ghr_...`, `ghu_...`, `github_pat_[A-Za-z0-9_]{82}` →
    `[REDACTED:github_token]`
  - **Generic bearer/API tokens**: `(api_key|apikey|token|secret|password|bearer)\\s*[:=]\\s*['"]?<value with 20+ chars>['"]?`
    where `<value>` matches `[A-Za-z0-9_\\-\\./+=]{20,}` → keep the
    label and replace the value with `[REDACTED:generic_token]`
  - **JWT-shaped strings**: `eyJ[A-Za-z0-9_\\-]+\\.eyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+`
    → `[REDACTED:jwt]`
  - **Slack tokens**: `xox[abprs]-[A-Za-z0-9-]{10,}` →
    `[REDACTED:slack_token]`

  Patterns are intentionally conservative — better a few false positives
  than leaking a real key. The orchestrator's transcript writer should
  invoke `redact/1` on every prompt and response BEFORE writing to disk
  per spec §14.

  Public API:
  - `redact/1` — applies all known patterns and returns the redacted
    string.
  - `patterns/0` — returns the canonical list of pattern names so other
    callers (e.g. tests, audit dashboards) can introspect coverage.
  - `contains_credential?/1` — boolean check for at least one match.
  """

  @aws_access_key_pattern ~r/\bAKIA[A-Z0-9]{16}\b/
  @github_token_pattern ~r/\b(?:ghp_|gho_|ghs_|ghr_|ghu_)[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b/
  @pem_pattern ~r/-----BEGIN ([A-Z ]+?)-----[\s\S]*?-----END \1-----/
  @jwt_pattern ~r/\beyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b/
  @slack_token_pattern ~r/\bxox[abprs]-[A-Za-z0-9\-]{10,}\b/
  @generic_token_pattern ~r/(?<label>(?:api[_-]?key|apikey|secret|token|password|bearer))\s*[:=]\s*['"]?(?<value>[A-Za-z0-9_\-\.\/+=]{20,})['"]?/i
  @aws_secret_label_pattern ~r/(?<label>(?:aws_secret_access_key|aws_secret|secret_access_key))\s*[:=]\s*['"]?(?<value>[A-Za-z0-9\/+=]{40})['"]?/i

  @type pattern_name ::
          :aws_access_key
          | :aws_secret
          | :pem
          | :github_token
          | :generic_token
          | :jwt
          | :slack_token

  @doc """
  Returns the redacted string. Non-binary input is returned unchanged
  (pragmatic: callers passing nil / atom shouldn't crash).
  """
  @spec redact(term()) :: term()
  def redact(text) when is_binary(text) do
    text
    |> redact_pem()
    |> redact_jwt()
    |> redact_github_token()
    |> redact_aws_access_key()
    |> redact_aws_secret_label()
    |> redact_slack_token()
    |> redact_generic_token()
  end

  def redact(other), do: other

  @doc """
  Returns the canonical list of recognized pattern names.
  """
  @spec patterns() :: [pattern_name()]
  def patterns,
    do: [:aws_access_key, :aws_secret, :pem, :github_token, :generic_token, :jwt, :slack_token]

  @doc """
  Returns `true` if at least one redactable pattern matches anywhere in
  the input. Useful for tests and for the orchestrator to log a
  `redactions_applied` counter.
  """
  @spec contains_credential?(String.t()) :: boolean()
  def contains_credential?(text) when is_binary(text) do
    Regex.match?(@pem_pattern, text) or
      Regex.match?(@jwt_pattern, text) or
      Regex.match?(@github_token_pattern, text) or
      Regex.match?(@aws_access_key_pattern, text) or
      Regex.match?(@aws_secret_label_pattern, text) or
      Regex.match?(@slack_token_pattern, text) or
      Regex.match?(@generic_token_pattern, text)
  end

  defp redact_pem(text) do
    Regex.replace(@pem_pattern, text, fn _match, kind ->
      slug =
        kind
        |> String.downcase()
        |> String.replace(" ", "_")

      "[REDACTED:pem_#{slug}]"
    end)
  end

  defp redact_jwt(text), do: Regex.replace(@jwt_pattern, text, "[REDACTED:jwt]")

  defp redact_github_token(text),
    do: Regex.replace(@github_token_pattern, text, "[REDACTED:github_token]")

  defp redact_aws_access_key(text),
    do: Regex.replace(@aws_access_key_pattern, text, "[REDACTED:aws_access_key]")

  defp redact_aws_secret_label(text) do
    Regex.replace(@aws_secret_label_pattern, text, fn match, _label, _value ->
      replace_label_value(match, "[REDACTED:aws_secret]")
    end)
  end

  defp redact_slack_token(text),
    do: Regex.replace(@slack_token_pattern, text, "[REDACTED:slack_token]")

  defp redact_generic_token(text) do
    Regex.replace(@generic_token_pattern, text, fn match, _label, _value ->
      replace_label_value(match, "[REDACTED:generic_token]")
    end)
  end

  # Reconstructs `<label><sep><replacement>` from the original match,
  # preserving the original separator (`:` or `=`) and the whitespace that
  # surrounded it. The surrounding quotes around the value are dropped for
  # simplicity per the module spec.
  defp replace_label_value(match, replacement) do
    case Regex.named_captures(~r/^(?<label>[^:=]+?)(?<sep>\s*[:=]\s*)/, match) do
      %{"label" => label, "sep" => sep} -> label <> sep <> replacement
      _ -> replacement
    end
  end
end
