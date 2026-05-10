defmodule SymphonyElixir.DuetCredentialRedactionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.CredentialRedaction

  describe "redact/1" do
    test "returns empty string for empty input" do
      assert CredentialRedaction.redact("") == ""
    end

    test "returns nil unchanged" do
      assert CredentialRedaction.redact(nil) == nil
    end

    test "returns atoms unchanged" do
      assert CredentialRedaction.redact(:hello) == :hello
    end

    test "returns integers unchanged" do
      assert CredentialRedaction.redact(42) == 42
    end

    test "returns plain text unchanged when no credentials are present" do
      text = "Just some normal prose with no secrets in it. Carry on."
      assert CredentialRedaction.redact(text) == text
    end

    test "redacts a bare AWS access key" do
      assert CredentialRedaction.redact(aws_access_key()) == "[REDACTED:aws_access_key]"
    end

    test "redacts an AWS access key embedded in surrounding text" do
      assert CredentialRedaction.redact("Found #{aws_access_key()} in config") ==
               "Found [REDACTED:aws_access_key] in config"
    end

    test "redacts multiple AWS access keys in the same string" do
      input = "first #{aws_access_key()} then #{aws_access_key("JKLMNOPQRSTUVWXY")} end"
      output = CredentialRedaction.redact(input)

      assert output == "first [REDACTED:aws_access_key] then [REDACTED:aws_access_key] end"
    end

    test "redacts a PEM RSA private key block" do
      pem = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEpAIBAAKCAQEAxabc123fakebase64payloadxyz
      moreLines==
      -----END RSA PRIVATE KEY-----
      """

      result = CredentialRedaction.redact(pem)

      assert result =~ "[REDACTED:pem_rsa_private_key]"
      refute result =~ "MIIEpAIBAAKCAQEA"
      refute result =~ "BEGIN RSA"
      refute result =~ "END RSA"
    end

    test "redacts a PEM CERTIFICATE block" do
      pem = """
      -----BEGIN CERTIFICATE-----
      ZmFrZSBjZXJ0aWZpY2F0ZSBwYXlsb2Fk
      -----END CERTIFICATE-----
      """

      result = CredentialRedaction.redact(pem)

      assert result =~ "[REDACTED:pem_certificate]"
      refute result =~ "ZmFrZSB"
    end

    test "replaces a multi-line PEM block with a single-line marker (no embedded newlines)" do
      pem =
        "-----BEGIN RSA PRIVATE KEY-----\nlineA\nlineB\nlineC\n-----END RSA PRIVATE KEY-----"

      assert CredentialRedaction.redact(pem) == "[REDACTED:pem_rsa_private_key]"
    end

    test "redacts a classic GitHub token" do
      token = "ghp_" <> String.duplicate("a", 36)
      assert CredentialRedaction.redact("token: " <> token) =~ "[REDACTED:github_token]"
      refute CredentialRedaction.redact("token: " <> token) =~ "ghp_aaaa"
    end

    test "redacts a GitHub fine-grained PAT (github_pat_<82 chars>)" do
      pat = "github_pat_" <> String.duplicate("A", 82)
      result = CredentialRedaction.redact("config: " <> pat)

      assert result =~ "[REDACTED:github_token]"
      refute result =~ pat
    end

    test "redacts a JWT-shaped string" do
      jwt =
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signaturePartHere1234567890"

      assert CredentialRedaction.redact("auth=" <> jwt) =~ "[REDACTED:jwt]"
      refute CredentialRedaction.redact("auth=" <> jwt) =~ "eyJhbGc"
    end

    test "redacts a Slack bot token" do
      assert CredentialRedaction.redact("slack: xoxb-1234567890-abcdefghij") =~
               "[REDACTED:slack_token]"
    end

    test "redacts a generic api_key value while preserving the label" do
      input = ~s(api_key: "sk-1234567890abcdefghij1234567890")
      result = CredentialRedaction.redact(input)

      assert result =~ "api_key"
      assert result =~ "[REDACTED:generic_token]"
      refute result =~ "sk-1234567890abcdefghij1234567890"
    end

    test "redacts a generic password value while preserving the label" do
      result = CredentialRedaction.redact("password=mysupersecretvaluehere1234")

      assert result =~ "password"
      assert result =~ "[REDACTED:generic_token]"
      refute result =~ "mysupersecretvaluehere1234"
    end

    test "does not redact a generic value below the 20-char threshold" do
      input = "token: shortvalue"
      assert CredentialRedaction.redact(input) == input
    end

    test "redacts an aws_secret_access_key value while preserving the label" do
      secret = String.duplicate("a", 40)
      input = "aws_secret_access_key=" <> secret
      result = CredentialRedaction.redact(input)

      assert result =~ "aws_secret_access_key"
      assert result =~ "[REDACTED:aws_secret]"
      refute result =~ secret
    end

    test "redacts multiple distinct credential types in a single pass" do
      github_token = "ghp_" <> String.duplicate("a", 36)

      input =
        """
        Here is an AWS key #{aws_access_key()}.
        Here is a GitHub token #{github_token}.
        Here is a Slack token xoxb-1234567890-abcdefghij.
        """

      result = CredentialRedaction.redact(input)

      assert result =~ "[REDACTED:aws_access_key]"
      assert result =~ "[REDACTED:github_token]"
      assert result =~ "[REDACTED:slack_token]"
      refute result =~ aws_access_key()
      refute result =~ "ghp_aaaa"
      refute result =~ "xoxb-1234567890"
    end

    test "treats a PEM block containing api_key text as a single PEM redaction" do
      pem =
        "-----BEGIN RSA PRIVATE KEY-----\napi_key: somethinglongenoughtomatch12345\n-----END RSA PRIVATE KEY-----"

      assert CredentialRedaction.redact(pem) == "[REDACTED:pem_rsa_private_key]"
    end
  end

  describe "patterns/0" do
    test "returns the canonical 7-name list" do
      assert CredentialRedaction.patterns() == [
               :aws_access_key,
               :aws_secret,
               :pem,
               :github_token,
               :generic_token,
               :jwt,
               :slack_token
             ]
    end
  end

  describe "contains_credential?/1" do
    test "returns false for empty string" do
      refute CredentialRedaction.contains_credential?("")
    end

    test "returns true for text containing an AWS access key" do
      assert CredentialRedaction.contains_credential?("see #{aws_access_key()} here")
    end

    test "returns false for plain prose with no credentials" do
      refute CredentialRedaction.contains_credential?("Just some prose, nothing secret.")
    end

    test "returns true for text containing only a JWT" do
      jwt =
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signaturePartHere1234567890"

      assert CredentialRedaction.contains_credential?(jwt)
    end
  end

  defp aws_access_key(suffix \\ "IOSFODNN7EXAMPLE"), do: "AKIA" <> suffix
end
