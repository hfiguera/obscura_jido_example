defmodule ObscuraJidoExample.PrivacyProfile do
  @moduledoc """
  Selects the text privacy profile and owns the optional shared native runtime.

  The native runtime is shared; each browser session retains its own vault.
  Provisioning is an explicit deployment step, never a request-time operation.
  """

  alias Obscura.Profile.Preparer

  def name, do: Application.get_env(:obscura_jido_example, :privacy_profile, :fast)

  def children do
    case name() do
      :fast ->
        []

      :efficient ->
        options = Application.get_env(:obscura_jido_example, :privacy_prepare_options, [])

        [
          {Preparer,
           name: __MODULE__,
           profile: :efficient,
           prepare_options: Keyword.merge(options, offline: true, allow_download: false)}
        ]
    end
  end

  def reference do
    case name() do
      :fast -> {:ok, :fast}
      :efficient -> native_reference()
    end
  end

  defp native_reference do
    case Preparer.runtime(__MODULE__) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, _reason} -> {:error, :privacy_unavailable}
    end
  catch
    :exit, _reason -> {:error, :privacy_unavailable}
  end
end
