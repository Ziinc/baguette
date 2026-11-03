defmodule Baguette.DNSTest do
  use ExUnit.Case, async: false

  alias Baguette.DNS

  test "reads the host's comma-separated servers, skipping what isn't an address" do
    assert DNS.parse("10.0.0.1, 2001:4860:4860::8888,nope,") ==
             [{10, 0, 0, 1}, {8193, 18528, 18528, 0, 0, 0, 0, 34952}]

    assert DNS.parse("") == []
  end

  test "on iOS, lookups use the hosts file and DNS with the given servers" do
    lookup = :inet_db.res_option(:lookup)
    servers = :inet_db.res_option(:nameservers)

    on_exit(fn ->
      :inet_db.set_lookup(lookup)
      :inet_db.res_option(:nameservers, servers)
    end)

    assert :ok = DNS.configure(:ios, [{192, 0, 2, 53}])
    assert :inet_db.res_option(:lookup) == [:file, :dns]
    assert {{192, 0, 2, 53}, 53} in :inet_db.res_option(:nameservers)
  end

  test "elsewhere, lookups are left alone" do
    lookup = :inet_db.res_option(:lookup)
    assert :ok = DNS.configure(:linux, [{192, 0, 2, 53}])
    assert :inet_db.res_option(:lookup) == lookup
  end
end
