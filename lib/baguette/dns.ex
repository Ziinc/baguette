defmodule Baguette.DNS do
  @moduledoc false
  # Hostname lookups on iOS. The BEAM's default (`native`) asks its
  # `inet_gethost` program, which iOS can't run, and iOS has no
  # `/etc/resolv.conf` for the BEAM's own resolver. So on iOS lookups use the
  # hosts file and that resolver (`[:file, :dns]`), with the system's DNS
  # servers, which the host passes as `-baguette_nameservers a,b,...`.

  require Logger

  @doc "Sets up hostname lookups for `platform`, with DNS `servers`."
  @spec configure(atom(), [:inet.ip_address()]) :: :ok
  def configure(platform \\ Baguette.platform(), servers \\ nameservers())

  def configure(:ios, servers) do
    if servers == [], do: Logger.warning("baguette: no DNS servers; lookups will fail")
    :ok = :inet_db.set_lookup([:file, :dns])
    Enum.each(servers, &(:ok = :inet_db.add_ns(&1)))
  end

  def configure(_platform, _servers), do: :ok

  @doc "The DNS servers the host passed."
  @spec nameservers() :: [:inet.ip_address()]
  def nameservers do
    case :init.get_argument(:baguette_nameservers) do
      {:ok, [[list]]} -> parse(List.to_string(list))
      _ -> []
    end
  end

  @doc false
  @spec parse(String.t()) :: [:inet.ip_address()]
  def parse(list) do
    for ip <- String.split(list, ",", trim: true),
        {:ok, address} <- [:inet.parse_address(String.to_charlist(String.trim(ip)))],
        do: address
  end
end
