# struct
defmodule User do
  defstruct name: "John", age: 30, membership: :gold
end

defmodule Example do
  @moduledoc """
  Documentation for `Example`.
  """

  use Application

  def start(_type, _args) do # not used param _type, _args; use underscore!
    Example.main()

    Supervisor.start_link([], strategy: :one_for_one)
  end

  require Integer

  alias UUID
  alias Module1, as: M1

  @y 5 # module variable / constant

  ##########################################################################################

  @doc """
  Hello world.

  ## Examples
      iex> Example.hello()
      :world
  """
  def hello do
    IO.puts(:world) # atom: constant value, name and value are the same
    IO.puts(:"hello world") # atom: constant value, name and value are the same
    IO.puts("world") # string
    IO.puts(UUID.uuid4())
  end

  def fn_case(status, name) do
    if status === :gold do
      IO.puts("Welcome #{name}")
    else
      IO.puts("Not Gold")
    end

    case status do
      :gold -> IO.puts("gold #{name}")
      :silver -> IO.puts("silver")
      :bronze -> IO.puts("bronze")
    end
  end

  def fn_strings do
    IO.puts("hello" <> " " <> "world" <> "!")
    IO.puts("special \n characters")
    IO.puts(?a)
  end

  def fn_types do
    a =  10
    a = a + 1.0 # dynamically typed
    b = 3.0
    IO.puts(a + b)
    :io.format("a: ~p, b: ~.20f\n", [a, b])
    IO.puts(Float.ceil(3.14, 1))
    IO.puts(Integer.gcd(10, 15))
  end

  def fn_compund_type do
    time = Time.new!(16, 30, 0, 0)
    IO.inspect(time) # not IO.puts(time)

    date = Date.new!(2021, 10, 10)
    IO.inspect(date)

    datetime = DateTime.new!(date, time, "Etc/UTC")
    IO.inspect(datetime)
    IO.puts(datetime.year)

    time_till = DateTime.diff(DateTime.utc_now(), datetime)
    IO.inspect(time_till)

    days = div(time_till, 24 * 60 * 60)
    hours = div(rem(time_till, 24 * 60 * 60), (60 * 60))
    IO.puts("#{days} days and #{hours} hours")
  end

  def fn_collection do
    # tuple
    memberships  = {:gold, :silver}
    memberships  = Tuple.append(memberships, :bronze)
    IO.inspect(memberships)

    prices = {5, 10, 15}
    avg = Tuple.sum(prices) / tuple_size(prices)
    IO.puts(avg)

    user1 = {"John", 30, :gold}
    IO.puts(elem(user1, 0))

    {name, age, membership} = user1
    IO.puts("#{name} #{age} #{membership}")

    # list
    users = [{"John", 30, :gold}, {"John", 30, :gold}, {"John", 30, :gold}]
    Enum.each(users, fn {name, age, membership} -> IO.puts("#{name} #{age} #{membership}") end)

    grades = [25, 50, 75, 100]
    for n <- grades, do: IO.puts(n)

    new_grades = for n <- grades, do: n + 5
    IO.inspect(new_grades)

    new_grades = new_grades ++ [150, 175]
    IO.inspect(new_grades)

    new_grades =  [5 | new_grades] # prepend
    IO.inspect(new_grades)

    even = for n <- new_grades, Integer.is_even(n), do: n
    IO.inspect(even)

    # map
    memberships_2  = %{gold: 3, silver: 2 }
    IO.puts(memberships_2.gold)
    memberships_3  = %{gold: :gold, silver: :silver }
    IO.puts(memberships_3.gold)
    IO.puts(memberships_3[:gold])

    # struct
    user_1 = %User{}
    user_2 = %User{name: "Jane", age: 25, membership: :silver}
    IO.inspect(user_1)
    IO.inspect(user_2)
    IO.inspect(user_2.age)
  end

  def fn_loop do
    for n <- 1..10 do
      IO.puts(n)
    end

    for n <- 1..10, rem(n, 2) == 0 do
      IO.puts(n)
    end

    for n <- 1..10, do: IO.puts(n * n)

    Enum.each(1..10, fn n -> IO.puts(n) end)
  end

  def fn_input do
    correct = :rand.uniform(11) - 1 # 1 to 11
    IO.puts("Enter your guess: ")
    guess = IO.gets("here") |> String.trim()
    IO.puts("Hello #{guess}")

    if String.to_integer(guess) == correct do
      IO.puts("right")
    else
      IO.puts("wrong")
    end
  end

  def fn_error do
    # @spec parse(binary(), 2..36) :: {integer(), remainder_of_binary :: binary()} | :error
    guess = IO.gets("here") |> String.trim() |> Integer.parse()
    IO.inspect(guess)

    n = 1
    case guess do
      {result, ""} when n >= 0 and n <= 10 -> IO.puts("1")
      {result, _} when n >= 0 and n <= 10 -> IO.puts("2")
      :error -> IO.puts("error")
    end
    # raise "error"
  end

  def print_numbers(nums) do
    nums |> Enum.join(" ") |> IO.puts()
  end

  def fn_functions do
    nums = [1, 2, 3, 4, 5]

    Enum.each(nums, fn n -> IO.puts(n) end) # higher order function

    new = Enum.map(nums, fn n -> n * n end)
    new_str = Enum.map(nums, &Integer.to_string/1) # capture operator: non-anonymous function to anonymous function
    IO.inspect(new_str)

    add = fn a, b -> a + b end
    IO.puts(add.(5, 10))
  end

  def main do
    IO.puts("main")

    # x = 5 # binding, warning!
    x = 10 # re-binding
    IO.puts(x)
    IO.puts(@y)

    # Example.hello()

    # name = "John" # string
    # status = Enum.random([:gold, :silver, :bronze]) # atom
    # Example.fn_case(status, name)

    # Example.fn_strings()

    # Example.fn_types()

    # Example.fn_compund_type()

    # Example.fn_loop()

    # Example.fn_collection()

    # Example.fn_input()

    # Example.fn_error()

    # Example.fn_functions()

    m1_value = M1.hello("John")
    IO.puts(m1_value)

  end

end

##########################################################################################
IO.puts("Runs at compile time")
Example.hello()
