defmodule Mix.Tasks.Baguette.StylesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Baguette.Styles

  test "names classes as Tailwind does" do
    assert Styles.class_name("flex_col") == "flex-col"
    assert Styles.class_name("w_1_2") == "w-1/2"
    assert Styles.class_name("min_w_1_12") == "min-w-1/12"
    assert Styles.class_name("mt_neg_2") == "-mt-2"
    assert Styles.class_name("inset_neg_1_2") == "-inset-1/2"
    assert Styles.class_name("p_0p5") == "p-0.5"
    assert Styles.class_name("rounded_t_2xl") == "rounded-t-2xl"
    assert Styles.class_name("border_l_2") == "border-l-2"
    assert Styles.class_name("cursor_not_allowed") == "cursor-not-allowed"
  end

  # The shape of rustdoc's JSON, cut down to what the task reads.
  defp rustdoc do
    %{
      "index" => %{
        "1" => %{"name" => "Styled", "inner" => %{"trait" => %{"items" => [2, 3, 4, 5, 6, 7]}}},
        "2" => %{"name" => "w_full", "inner" => %{"function" => %{"sig" => sig([])}}},
        "3" => %{"name" => "w", "inner" => %{"function" => %{"sig" => sig([["length", %{}]])}}},
        "4" => %{"name" => "debug", "inner" => %{"function" => %{"sig" => sig([])}}},
        "5" => %{
          "name" => "style",
          "inner" => %{
            "function" => %{
              "sig" => %{"inputs" => [["self", %{}]], "output" => %{"borrowed_ref" => %{}}}
            }
          }
        },
        "6" => %{"name" => "cursor_grab", "inner" => %{"function" => %{"sig" => sig([])}}},
        "7" => %{"name" => "Item", "inner" => %{"assoc_type" => %{}}},
        "8" => %{"name" => "Other", "inner" => %{"trait" => %{"items" => []}}}
      }
    }
  end

  defp sig(args),
    do: %{
      "inputs" => [["self", %{"generic" => "Self"}] | args],
      "output" => %{"generic" => "Self"}
    }

  test "takes Styled's methods that take no argument, in the stable categories" do
    assert Styles.methods(rustdoc()) == ["cursor_grab", "w_full"]
  end

  test "writes a table sorted by class" do
    source = Styles.render(["w_full", "mt_neg_2"], "0.3.9")
    assert source =~ ~s[    ("-mt-2", |r| r.mt_neg_2()),\n    ("w-full", |r| r.w_full()),]
    assert source =~ "gpui-pre 0.3.9"
  end

  test "refuses two methods with one class" do
    assert_raise Mix.Error, ~r/share a class name/, fn ->
      Styles.render(["w_1_2", "w_1_2"], "x")
    end
  end
end
