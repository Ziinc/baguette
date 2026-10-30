defmodule Baguette.Patch do
  @moduledoc """
  What changed between two trees (`Baguette.Tree`), as the patch the native
  host applies in place of a whole new tree.

  A patch is a list of operations, applied in order. `at` is the path from
  the root to a node, as child indices:

    * `%{"op" => "replace", "at" => at, "node" => node}` - a new node.
    * `%{"op" => "attrs", "at" => at, "a" => attrs}` - all new attributes.
    * `%{"op" => "splice", "at" => at, "start" => i, "delete" => n, "c" => nodes}` -
      removes `n` children from index `i` and inserts `nodes` there.

  Children are matched by position. Equal leading and trailing children
  are kept, so adding or removing children anywhere is one splice. An
  element whose `id` changed is a new element, and is replaced.
  """

  @type op :: %{String.t() => term()}

  @spec diff(Baguette.Tree.tree() | nil, Baguette.Tree.tree() | nil) :: [op()]
  def diff(old, new), do: old |> diff(new, []) |> Enum.reverse()

  defp diff(same, same, _at), do: []

  defp diff(%{"t" => tag, "a" => a1} = old, %{"t" => tag, "a" => a2} = new, at) do
    if a1["id"] == a2["id"] do
      attrs = if a1 == a2, do: [], else: [%{"op" => "attrs", "at" => at, "a" => a2}]
      children(old["c"] || [], new["c"] || [], at, attrs)
    else
      [replace(at, new)]
    end
  end

  defp diff(_old, new, at), do: [replace(at, new)]

  defp replace(at, node), do: %{"op" => "replace", "at" => at, "node" => node}

  # Ops come out reversed, so later ones go on the front.
  defp children(old, new, at, ops) do
    prefix = common(old, new)
    {old_rest, new_rest} = {Enum.drop(old, prefix), Enum.drop(new, prefix)}
    suffix = common(Enum.reverse(old_rest), Enum.reverse(new_rest))
    old_mid = Enum.drop(old_rest, -suffix)
    new_mid = Enum.drop(new_rest, -suffix)
    paired = min(length(old_mid), length(new_mid))

    ops =
      Enum.zip(old_mid, new_mid)
      |> Enum.with_index(prefix)
      |> Enum.reduce(ops, fn {{o, n}, i}, ops -> diff(o, n, at ++ [i]) ++ ops end)

    case {Enum.drop(old_mid, paired), Enum.drop(new_mid, paired)} do
      {[], []} ->
        ops

      {removed, added} ->
        splice = %{
          "op" => "splice",
          "at" => at,
          "start" => prefix + paired,
          "delete" => length(removed),
          "c" => added
        }

        [splice | ops]
    end
  end

  defp common([x | xs], [x | ys]), do: 1 + common(xs, ys)
  defp common(_, _), do: 0

  @doc "Applies `patch` to `tree`, as the native host does."
  @spec apply(Baguette.Tree.tree() | nil, [op()]) :: Baguette.Tree.tree() | nil
  def apply(tree, patch), do: Enum.reduce(patch, tree, &apply_op/2)

  defp apply_op(%{"at" => at} = op, tree), do: update(tree, at, &change(&1, op))

  defp change(_node, %{"op" => "replace", "node" => node}), do: node
  defp change(node, %{"op" => "attrs", "a" => attrs}), do: %{node | "a" => attrs}

  defp change(node, %{"op" => "splice", "start" => start, "delete" => n, "c" => added}) do
    {before, rest} = Enum.split(node["c"], start)
    %{node | "c" => before ++ added ++ Enum.drop(rest, n)}
  end

  defp update(node, [], fun), do: fun.(node)

  defp update(%{"c" => children} = node, [i | at], fun),
    do: %{node | "c" => List.update_at(children, i, &update(&1, at, fun))}
end
