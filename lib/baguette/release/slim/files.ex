defmodule Baguette.Release.Slim.Files do
  @moduledoc false

  @doc "The bytes in `path`: a file's size, or the sum of a directory's files."
  def size(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path |> File.ls!() |> Enum.reduce(0, &(&2 + size(Path.join(path, &1))))

      {:ok, %{size: size}} ->
        size

      {:error, _} ->
        0
    end
  end

  @doc "Removes `rel` under `root`, returning its report entry."
  def remove!(root, rel, reason) do
    path = Path.join(root, rel)
    bytes = size(path)
    File.rm_rf!(path)
    %{path: rel, bytes: bytes, reason: reason}
  end
end
