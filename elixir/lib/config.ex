defmodule App.Config do
  @moduledoc """
  The service's configuration: one secret, one config object, one block.

  container_config.env names all three:

      AWS_SECRET_NAME   the Secrets Manager secret - credentials and API keys only:
                        {"credentials": {"<id>": {"username": ..., "password": ...}},
                         "api_keys": {"<id>": "<key>"}}
      CONFIG_BUCKET     the config object in S3: every other setting, as JSON
      CONFIG_KEY
      CONFIG_BLOCK      the block of the config object this deployment runs

  A block may name a PROFILE from the object's "profiles"; the block's own keys
  win over its profile's. A setting ending in _CREDENTIAL holds a credential
  id, looked up in the secret.

  With MODE=local nothing is read from AWS: the config object is the local
  copy, services/<basename of CONFIG_KEY>, and there are no credentials or API
  keys. CONFIG_KEY and CONFIG_BLOCK a local run does not have are read from
  container_config.env. Read once: `get!/1` caches it, so a change takes a
  restart. Mirrors src/config.py in the Python layer.
  """

  @credential_suffix "_CREDENTIAL"
  @env_file "container_config.env"

  defstruct block: nil, settings: %{}, credentials: %{}, api_keys: %{}

  @type t :: %__MODULE__{
          block: String.t(),
          settings: map,
          credentials: map,
          api_keys: map
        }

  @doc "The block's settings, on top of its PROFILE's."
  @spec resolve_block(map, String.t()) :: {:ok, map} | {:error, String.t()}
  def resolve_block(data, block_name) do
    case Map.fetch(data, block_name) do
      :error ->
        {:error, "the config object has no block #{inspect(block_name)}"}

      {:ok, block} when not is_map(block) ->
        {:error, "block #{inspect(block_name)} is not a JSON object"}

      {:ok, block} ->
        merge_profile(data, block_name, block)
    end
  end

  defp merge_profile(data, block_name, block) do
    case Map.get(block, "PROFILE") do
      profile_name when profile_name in [nil, ""] ->
        {:ok, block}

      profile_name ->
        case data |> Map.get("profiles", %{}) |> Map.get(profile_name) do
          profile when is_map(profile) ->
            {:ok, Map.merge(profile, block)}

          _ ->
            {:error,
             "block #{inspect(block_name)} names profile #{inspect(profile_name)}, " <>
               "which the config object does not have"}
        end
    end
  end

  @doc "Every *_CREDENTIAL setting names a credential the secret holds."
  @spec check_credentials(map, map) :: :ok | {:error, String.t()}
  def check_credentials(settings, credentials) do
    missing =
      for {key, value} <- settings,
          String.ends_with?(key, @credential_suffix),
          not Map.has_key?(credentials, value),
          do: "#{key}=#{value}"

    case Enum.sort(missing) do
      [] -> :ok
      sorted -> {:error, "credential ids not in the secret: #{Enum.join(sorted, ", ")}"}
    end
  end

  # An environment variable; for a local run, else container_config.env's.
  defp setting(name, local) do
    value = System.get_env(name, "")

    if value != "" or not local or not File.exists?(@env_file) do
      value
    else
      @env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_value("", fn line ->
        if String.starts_with?(line, name <> "="),
          do: line |> String.replace_prefix(name <> "=", "") |> String.trim()
      end)
    end
  end

  defp region, do: System.get_env("AWS_REGION", "ap-southeast-2")

  defp read_config_object(true) do
    case setting("CONFIG_KEY", true) do
      "" -> {:error, "CONFIG_KEY is not set"}
      key -> File.read(Path.join("services", Path.basename(key)))
    end
  end

  defp read_config_object(false) do
    bucket = setting("CONFIG_BUCKET", false)
    key = setting("CONFIG_KEY", false)

    if bucket == "" or key == "" do
      {:error, "CONFIG_BUCKET and CONFIG_KEY must both be set"}
    else
      case bucket |> ExAws.S3.get_object(key) |> ExAws.request(region: region()) do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, reason} -> {:error, "get s3://#{bucket}/#{key}: #{inspect(reason)}"}
      end
    end
  end

  # Secrets Manager through ex_aws's generic JSON request: no extra package.
  defp read_secret do
    case System.get_env("AWS_SECRET_NAME", "") do
      "" ->
        {:ok, %{}}

      name ->
        %ExAws.Operation.JSON{
          http_method: :post,
          service: :secretsmanager,
          headers: [
            {"x-amz-target", "secretsmanager.GetSecretValue"},
            {"content-type", "application/x-amz-json-1.1"}
          ],
          data: %{"SecretId" => name}
        }
        |> ExAws.request(region: region())
        |> case do
          {:ok, %{"SecretString" => string}} -> Jason.decode(string)
          {:error, reason} -> {:error, "read #{name} from secrets manager: #{inspect(reason)}"}
        end
    end
  end

  @doc "Reads the configuration; `get!/1` is the cached form."
  @spec load(boolean) :: {:ok, t} | {:error, String.t()}
  def load(local) do
    with block_name when block_name != "" <- setting("CONFIG_BLOCK", local),
         {:ok, raw} <- read_config_object(local),
         {:ok, data} <- Jason.decode(raw),
         {:ok, settings} <- resolve_block(data, block_name) do
      config = %__MODULE__{block: block_name, settings: settings}
      if local, do: {:ok, config}, else: with_secret(config)
    else
      "" -> {:error, "CONFIG_BLOCK is not set"}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_secret(config) do
    with {:ok, secret} <- read_secret(),
         credentials = Map.get(secret, "credentials", %{}),
         :ok <- check_credentials(config.settings, credentials) do
      {:ok, %{config | credentials: credentials, api_keys: Map.get(secret, "api_keys", %{})}}
    end
  end

  @doc "The configuration, read once at the first call; a change takes a restart."
  @spec get!(boolean) :: t
  def get!(local) do
    case :persistent_term.get({__MODULE__, local}, nil) do
      nil ->
        case load(local) do
          {:ok, config} ->
            :persistent_term.put({__MODULE__, local}, config)
            config

          {:error, reason} ->
            raise "configuration: #{reason}"
        end

      config ->
        config
    end
  end
end
