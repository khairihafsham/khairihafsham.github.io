How do you order events that happens between and within distributed processes? Let’s assume that each of the processes keeps a list of:

1. All the events that happened within itself
2. And all events related to sending and receiving messages between processes

To sort the list of events, we would need to determine if a particular event _happens before_ another event. One option would be to tag each event with DateTime of when the event occurred. Alternatively, one could also use Unix Timestamp, instead of DateTime, and avoid all the hassle of timezone and daylight savings time. But, there is no guarantee that time runs the same in all the distributed processes. Time synchronisation with NTP have an accuracy level within tens of milliseconds, assuming the network is good and polled within 36 hours[^1]. Another risk would be _Leap Second_ and the documented problems arising from it[^2].

DateTime and Unix Timestamp are considered as _Physical Clocks_. Alternative to them are _Logical Clock_ and we are going to implement one of such clock called Lamport Timestamp (or Lamport’s Logical Clock). The implementation is heavily inspired by the famous paper by Leslie Lamport, titled “Time, Clocks, and the Ordering of Events in a Distributed System”[^3]. Anytime _clock_ is mentioned after this, it will refer to _Logical Clock_. Below are a few definitions that has been extracted from the paper.

## Definition (DEF)

1. If `a` and `b` are events in the same process and `a` happens before `b`, then `a -> b`. The `->` means _happens before_.
2. If `a` is the sending of a message by one process and `b` is the receipt of the same message by another process, then `a -> b`.
3. If `a -> b` and `b -> c` then `a -> c`.  This means the ordering of the events are transitive.
4. Two distinct events `a` and `b` are said to be concurrent if `a -/> b` and `b -/> a`. This would happen if `a` and `b` happens in separate processes and there were no messages sent or received among the two processes between event `a` and `b`.

## Distributed events between processes

The logical clock can be implemented simply as a counter. To view which clock belongs to which process, we’ll create a `Clock` struct with a `timestamp` field to act as a counter and a `process_name` to identify the process it belongs to. For convenience, the code below also includes two functions for interfacing with the `Clock`:

1. `increment` which returns a new `Clock` with an incremented timestamp
2. `timestamp` to return the timestamp value of a `Clock`

```elixir
defmodule Clock do
  defstruct [:timestamp, :process_name]

  def increment(clock = %Clock{timestamp: timestamp}) do
    %Clock{ clock | timestamp: timestamp + 1 }
  end

  def timestamp(clock) do
    Map.get(clock, :timestamp) 
  end
end
```

For events, we would want to know the name of the event as well as when it happens. So, a clock is needed as well. Here is an example of `Event` struct that we’ll be using later on.

```elixir
defmodule Event do
  defstruct [:name, :clock]

  def timestamp(event) do
    Map.get(event, :clock)
    |> Map.get(:timestamp)
  end

  def process_name(event) do
    Map.get(event, :clock)
    |> Map.get(:process_name)
  end
end
```

## Events ordering

Let’s build something to demonstrate the clock and ordering of events between distributed processes. We’ll emulate distributed processes using `GenServer` and the application we’ll build is the Worst Random String Generator (WRSG)

We would not focus on actually building the logic for the Generator. The goal would be to demonstrate a distributed system that satisfies DEF 1 until DEF 4. 

### Implementation Rules (IR)

The implementation rules for the events and clock are quite straightforward:

1. Each process will have its internal logical clock
2. When an event happens within the process, increment the clock and assign it to the event
3. When a process wants to send a message to another process, it will create a `Sent` event
4. When process `k` sends a message to process `j`, the message must contain the `timestamp` from process `k`’s clock
5. When a process receives a message from another process, it will create a `Received` event

We’ll start simple, with intra process events. The WRSG will be generating strings one char at a time. Every time the process receives a command to generate a char, it will create an event and observes the IR1 and IR2 above.

Here is the starting code:

```elixir
require Event
require Clock

defmodule Generator do
  use GenServer

  def generate_char(name) do
    GenServer.cast(name, :generate_char) 
  end

  def get_events(name) do
    GenServer.call name, :events  
  end

  def start_process(name) do
    GenServer.start_link __MODULE__, %{name: name}, name: name 
  end

  ### GENSERVER IMPLEMENTATIONS ###

  @impl true
  def init(%{name: name}) do
    {:ok, %{name: name, events: [], clock: %Clock{process_name: name, timestamp: 0}}} 
  end

  @doc """
  Returns all the events stored in the state
  """
  @impl true
  def handle_call(:events, _from, state = %{ events: events }) do
    {:reply, events, state} 
  end

  @doc """
  Process use this to generate char internally
  """
  @impl true
  def handle_cast(:generate_char, state = %{clock: clock, events: events}) do
    updated_clock = Clock.increment(clock)
    new_event = %Event{name: :generate_char, clock: updated_clock}
    state = %{ state | clock: updated_clock }

    {:noreply, %{state | events: [ new_event | events] } }
  end  
end
```

The code uses the `Clock` and `Event` structs defined earlier. When the process starts, in `init`, you’ll notice that the process initializes a `Clock` and stores it in its state. This will be its internal logical Clock and fulfils IR1.

Next, in `handle_cast(:generate_char, ...)`, the process:

1. Gets its internal clock and increment it
2. Create a new `Event` with the updated clock
3. Updates its internal clock

Let’s try running this in `iex` (it is assumed that `Clock`, `Event` and `Generator` are already compiled)

```elixir
iex> Generator.start_process(:k)
iex> Generator.generate_char(:k)
iex> Generator.generate_char(:k)
iex> Generator.get_events(:k)
[
  %Event{clock: %Clock{process_name: :k, timestamp: 2}, name: :generate_char},
  %Event{clock: %Clock{process_name: :k, timestamp: 1}, name: :generate_char}
]
```

Events within a process are simple enough. We’ll move on to the interesting bit, combining with events between processes. The goal is to have 3 processes, each with its task to complete and have messages sent from one process to another. Below is a space-time diagram to illustrate what we want to achieve.

![](lamport-space-time-diagram.png)

Each vertical line is a process, the arrows are messages being sent from one process to another and each dot is an event. Here the events are colour coded. The vertical direction also helps to display movement of “time”, bottom to top representing oldest to latest. 

If we would like our processes to behave as in the diagram above, calling `generate_char` from `iex` will not be adequate. We’ll need a way to inform the process of the tasks that it needs to perform. To achieve that, we’ll add a new state to the process, which is an anonymous function that will contain the necessary steps for the process to execute. Since the tasks for the process are within the anonymous function, we’ll need a way to kick off the process, let’s create a new function for that as well. Here are the changes and new methods.

```elixir
defmodule Generator do
  # Only showing the changes from the previous Generator code

  # func will be function that contains the tasks to be executed
  # by the process when run() is called
  def start_process(name, func) do
    GenServer.start_link __MODULE__, %{name: name, func: func}, name: name 
  end

  def run(name) do
    GenServer.cast name, :run
  end

  ### GENSERVER IMPLEMENTATIONS ###

  @impl true
  def init(%{name: name, func: func}) do
    {:ok, %{name: name, func: func, events: [], clock: %Clock{process_name: name, timestamp: 0}}} 
  end

  @doc """
  This is for kickstarting the execution
  """
  @impl true
  def handle_cast(:run, state = %{ func: func }) do
    func.()        

    {:noreply, state}
  end
end
```

Fire up the `iex` again and lets try to generate the same list of events as we did previously.

```elixir
iex> fun = fn() ->
   > Generator.generate_char(:k)
   > Generator.generate_char(:k)
   > end
iex> Generator.start_process(:k, fun)
iex> Generator.run(:k)
iex> Generator.get_events(:k)
[
  %Event{clock: %Clock{process_name: :k, timestamp: 2}, name: :generate_char},
  %Event{clock: %Clock{process_name: :k, timestamp: 1}, name: :generate_char}
]
```

Great! Now we could start different `Generator` processes that will run different steps if needed. Next, we need a few functions to `send` and `receive` messages between processes. A process will use these functions to ask the other process to do work. For convenience, a few functions also being added to start off the 3 difference processes including the tasks that each process should be executing as well as a function to gather all the events from all the processes.

```elixir
defmodule Generator do
  # Only showing the changes from the previous Generator code
 def start_process_k do
    fun = fn() ->
      Generator.generate_char(:k)  
      Generator.send_generate_message(:k, :j)
      Generator.generate_char(:k)  
    end

    Generator.start_process(:k, fun)
  end

  def start_process_j do
    fun = fn() ->
      Generator.generate_char(:j)  
      Generator.send_generate_message(:j, :i)
      Generator.generate_char(:j)  
    end

    Generator.start_process(:j, fun)
  end

  def start_process_i do
    fun = fn() ->
      Generator.generate_char(:i)  
    end

    Generator.start_process(:i, fun)
  end

  def get_all_events do
    get_events(:k)
    |> Enum.concat(get_events(:j))
    |> Enum.concat(get_events(:i))
  end

  def send_generate_message(from, to) do
    GenServer.cast from, {:send_generate_message, to}  
  end

  ### GENSERVER IMPLEMENTATIONS ###

  @doc """
  This is to simulate an API for a process to receive message from other processes to generate chars
  """
  @impl true
  def handle_cast({ :generate, from }, state = %{ name: name }) do
    GenServer.cast name, {:received, from}
    run(name)

    {:noreply, state}
  end

  @doc """
  A process uses this function to send a message to other process
  """
  @impl true
  def handle_cast({ :send_generate_message, to}, state = %{ name: name, events: events, clock: clock }) do
    updated_clock = Clock.increment(clock)
    new_event = %Event{name: :sent_message, clock: updated_clock }
    state = %{ state | events: [ new_event | events ] }

    GenServer.cast to, { :generate, name }

    {:noreply, %{ state | clock: updated_clock }}
  end

  @doc """
  Here is the logic for creating an event to indicate the process has received a message.
  """
  @impl true
  def handle_cast({ :received, from }, state = %{ events: events, clock: clock }) do
    updated_clock = Clock.increment(clock)
    new_event = %Event{name: "received from #{from}", clock: updated_clock}
    state = %{ state | events: [ new_event | events] }

    {:noreply, %{ state | clock: updated_clock }}
  end
end
```

The main changes surround the three new `handle_cast` functions. First is `handle_cast({ :generate, ...`, this is how the processes can receive a message from another process to begin executing its tasks. Before it calls `run` notice that, the first thing a process does when it gets a `:generate` message is to invoke `handle_cast({ :received, ...`. This function’s main goal is to create a new event to mark that it has received a message.  The last function is `handle_cast({ :send_generate_message, ...`, this function’s main purpose is to create a new event before actually sending the message.

Let’s give it a run in `iex`

```elixir
iex> Generator.start_process_k
iex> Generator.start_process_j
iex> Generator.start_process_i
iex> Generator.run :k
```


Now that we’ve run all the processes, if we call `Generator.get_all_events()` and try to sort the resulting list of events, we should get something like below:

```elixir
iex> events = Generator.get_all_events()
iex> Enum.sort(events, &(Event.timestamp(&1) > Event.timestamp(&2)))
[
  %Event{clock: %Clock{process_name: :j, timestamp: 4}, name: :generate_char},
  %Event{clock: %Clock{process_name: :j, timestamp: 3}, name: "sent to i"},
  %Event{clock: %Clock{process_name: :k, timestamp: 3}, name: :generate_char},
  %Event{clock: %Clock{process_name: :i, timestamp: 2}, name: :generate_char},
  %Event{clock: %Clock{process_name: :j, timestamp: 2}, name: :generate_char},
  %Event{clock: %Clock{process_name: :k, timestamp: 2}, name: "sent to j"},
  %Event{clock: %Clock{process_name: :i, timestamp: 1}, name: "received from j"},
  %Event{clock: %Clock{process_name: :j, timestamp: 1}, name: "received from k"},
  %Event{clock: %Clock{process_name: :k, timestamp: 1}, name: :generate_char}
]
```

The events are not sorted properly. There are a couple of reasons for this, but one of them is because our implementation violated DEF 2. To fix that, we have to alter our implementation rules a bit. Changes are in bold:

### Updated Implementation Rules (UIR)
1. Each process will have its internal logical clock
2. When an event happens within the process, increment the clock and assign it to the event
3. When a process wants to send a message to another process, it will create a `Sent` event
4. When a process receives a message from another process, it will:
	1. **Updates its internal logical clock to `max(message_timestamp, process_timestamp)`**
	2. **Create a `received` event**

Let’s update a few functions. Changes are marked in the code.

```elixir
defmodule Generator do

 ### GENSERVER IMPLEMENTATIONS ###

  @doc """
  This is to simulate an API for a process to receive message from other processes to generate chars
  """
  @impl true
  def handle_cast({ :generate, message_timestamp, from }, state = %{ name: name }) do
    # CHANGE: added message_timestamp of sender
    GenServer.cast name, {:received, message_timestamp, from}
    run(name)

    {:noreply, state}
  end

  @impl true
  def handle_cast({ :send_generate_message, to}, state = %{ name: name, events: events, clock: clock }) do
    updated_clock = Clock.increment(clock)
    new_event = %Event{name: "sent to #{to}", clock: updated_clock }
    state = %{ state | events: [ new_event | events ] }

    # CHANGE send process timestamp to receiver
    GenServer.cast to, { :generate, %Clock.timestamp(updated_clock), name }

    {:noreply, %{ state | clock: updated_clock }}
  end

  @impl true
  def handle_cast({ :received, message_timestamp, from }, state = %{ events: events, clock: clock }) do
    # CHANGE take whichever the latest timestamp and create a new event using it
    latest_timestamp = max(Clock.timestamp(clock), message_timestamp)
    updated_clock = %Clock{ clock | timestamp: latest_timestamp + 1 }

    new_event = %Event{name: "received from #{from}", clock: updated_clock}
    state = %{ state | events: [ new_event | events] }

    {:noreply, %{ state | clock: updated_clock }}
  end
end
```

If we ran the processes, get all the events and sort them, the list should look something like below:

```elixir
[
  %Event{clock: %Clock{process_name: :i, timestamp: 7}, name: :generate_char},
  %Event{clock: %Clock{process_name: :i, timestamp: 6}, name: "received from j"},
  %Event{clock: %Clock{process_name: :j, timestamp: 6}, name: :generate_char},
  %Event{clock: %Clock{process_name: :j, timestamp: 5}, name: "sent to i"},
  %Event{clock: %Clock{process_name: :j, timestamp: 4}, name: :generate_char},
  %Event{clock: %Clock{process_name: :j, timestamp: 3}, name: "received from k"},
  %Event{clock: %Clock{process_name: :k, timestamp: 3}, name: :generate_char},
  %Event{clock: %Clock{process_name: :k, timestamp: 2}, name: "sent to j"},
  %Event{clock: %Clock{process_name: :k, timestamp: 1}, name: :generate_char}
]
```

Now it looks better. But, there are a couple of events that still have the same timestamp and they can swap places on each ordering because their value are the same. These events are an example of `concurrent` events, as mentioned in DEF 4. And this particular kind of ordering is called `partial ordering`.

The paper suggest that we could achieve `total ordering`, where there are no ambiguity or events swapping places on each ordering, if we can find a way to break the tie. One way to achieve that is to give each process a weight and use the weight as a tiebreaker. For example, we could determine that process `k > j > i` and if there are any events that share the same `timestamp`, we could fall back to the process hierarchy to determine which event sits higher in the ordering. Since in Elixir, inequality operation of atoms will use their string value, this can be achieved by changing the sorting logic to:

```elixir
&((Event.timestamp(&1) > Event.timestamp(&2)) || ((Event.timestamp(&1) == Event.timestamp(&2) && Event.process_name(&1) > Event.process_name(&2)))
```

So far, we have learned about how to use Logical Clocks instead of Physical Clocks for generating and ordering events in a distributed process. In part 2, we’ll explore how to use `Lamport Timestamp` for making decision within a distributed system and how to handle out of order events.

[^1]:	[https://tools.ietf.org/html/rfc5905](https://tools.ietf.org/html/rfc5905)

[^2]:	[Leap second issues](https://en.wikipedia.org/wiki/Leap_second#Issues_created_by_insertion_(or_removal)_of_leap_seconds)

[^3]:	https://lamport.azurewebsites.net/pubs/time-clocks.pdf