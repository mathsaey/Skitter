defmodule Skitter.Component.DSL do
  @moduledoc """
  DSL to define skitter components.

  This module offers the `component/3` macro, which you should use if you want
  to implement a component. Besides this, this module offers a set of macros
  which can be used at various places inside the body of `component/3`.
  Do not use these macros outside the context of `component/3`, as they rely
  on some of its AST transformations to work.

  Developers should prefer the use of the `component/3` DSL over the
  implementation of the `Skitter.Component` behaviour. This is the case for
  the following reasons:
  - The DSL is created for end users, while the `Skitter.Component` behaviour
  is intended for internal use by the skitter runtime. Therefore, the DSL code
  is less likely to break.
  - Modules generated by the DSL will implement the `Skitter.Component`
  behaviour by default. Besides this, the DSL will protect the programmer
  against some easy to make mistakes which the behaviour cannot verify.
  For instance, the DSL will check that a component which does not specify the
  `state_change` effect does not modify its instance.
  - Finally, the DSL automatically generates default code for most of the
  required callbacks. Thus, using the DSL will drastically cut down on the
  amount of boilerplate code the programmer has to write.

  To show how the DSL works, let's look at a component which separates numbers
  based on whether or not they are greater or smaller than 5, or equal to it.

  ```
  component SmallerThan5, in: input, out: [greater, smaller, equal] do
    "Verify if data is smaller or greater than 5, of it is equal to 5"

    react value do
      case value do
        5 -> spit value ~> equal
        x when x < 5 -> spit value ~> smaller
        x when x > 5 -> spit value ~> greater
      end
    end
  end
  ```

  This example shows the minimum of code a component developer should provide
  to create a valid component. At the very least, the following should be
  provided:

  - A "header", which specifies the name of the component, as well as the ports
    this component defines (`out` ports can be omitted if there are none).
  - An implementation of `react/3`

  Besides this, a developer can specify a description (shown in our example),
  and the effects this component may have. Furthermore, the various macros
  documented in this module can be used to implement various callbacks defined
  in `Skitter.Component`. Both of these are described in the following sections.

  ## Effects

  effects are specified with the following syntax:
  `effect effect_name [property1, property2]`. Properties are optional and can
  be omitted, in that case effects are specified as: `effect effect_name`.
  The component macro will provide an error if the effect is not correct.
  Multiple effects can be specified for a single component.

  The following list contains all valid effects:
  - `effect state_change`
  - `effect external_effect`

  Furthermore, the `state_change` effect has one possible property:
  `hidden`. This would be declared as: `effect state_change hidden`

  ## Callbacks

  This module defines macros that can automatically generate custom functions
  which implement the callbacks defined in `Skitter.Component`. The use of
  these callbacks is documented in their specific documentation section.

  When reading these, be aware that `component/3` will perform a lot of
  transformations on the component code which it receives, therefore it is
  generally not possible to call these macros directly. Instead, the
  documentation will specify how these macros can be used.
  """

  import Skitter.Component.DefinitionError

  # ----------------- #
  # Shared Macro Code #
  # ----------------- #
  # Code used by both `component/3` and various internal macros.

  # Constants
  # ---------

  @valid_effects [state_change: [:hidden], external_effect: []]

  # Transform the calls to the following callbacks
  # See: transform_component_callbacks(body, meta)
  # All of these callbacks are handled by the same function.
  # However, arguments to these calls are handled slightly differently.
  @component_callbacks_single_arg [
    # Only accept a single argument, which should not be modified
    :init,
    :restore,
    :clean_checkpoint
  ]
  @component_callbacks_arglst [
    # Accept an arbitrary amount of arguments, which are wrapped in a list
    :react
  ]
  @component_callbacks_no_args [
    # Don't accept any arguments besides the function body
    :terminate,
    :checkpoint
  ]

  # Generate default implementations for the following callbacks.
  # See: generate_default_callbacks(meta, body)
  @default_callbacks [
    :init,
    :terminate,
    :checkpoint,
    :restore,
    :clean_checkpoint
  ]

  # AST Transformations
  # -------------------

  # Transform a port name (which is just a standard elixir name) into  a symbol
  # e.g foo becomes :foo
  # If the name is ill-formed, return an {:error, form} pair.
  defp transform_port_name({name, _env, nil}), do: name
  defp transform_port_name(any), do: {:error, any}

  # Transform all instances of 'instance' into 'instance()'
  # This is done to avoid ambiguous uses of instance, which
  # will cause elixir to show a warning.
  defp transform_instance(body) do
    Macro.postwalk(body, fn
      {:instance, env, atom} when is_atom(atom) ->
        {:instance, env, []}

      any ->
        any
    end)
  end

  # Wrap a body with try/do if the `error/1` macro is used.
  defp add_skitter_error_handler(body) do
    if count_occurrences(:error, body) >= 1 do
      quote generated: true do
        try do
          unquote(body)
        catch
          {:skitter_error, reason} -> {:error, reason}
        end
      end
    else
      quote generated: true do
        unquote(body)
      end
    end
  end

  # Utility Functions
  # -----------------

  # Count the occurrences of a given symbol in an ast.
  defp count_occurrences(symbol, ast) do
    {_, n} =
      Macro.postwalk(ast, 0, fn
        ast = {^symbol, _env, _args}, acc -> {ast, acc + 1}
        ast, acc -> {ast, acc}
      end)

    n
  end

  # -------------- #
  # Error Checking #
  # -------------- #

  # Inject an error if a certain symbol is not present in an AST.
  defp use_or_error(body, symbol, error) do
    if count_occurrences(symbol, body) >= 1 do
      nil
    else
      inject_error error
    end
  end

  # -------------------- #
  # Component Generation #
  # -------------------- #

  @doc """
  Create a skitter component.

  This macro serves as the entry point of the `Skitter.Component.DSL` DSL.
  Please refer to the module documentation for additional details.
  """
  defmacro component(name, ports, do: body) do
    # Get metadata from header
    full_name = module_name_to_snake_case(Macro.expand(name, __CALLER__))
    {in_ports, out_ports} = read_ports(ports)

    # Extract metadata from body AST
    {body, desc} = extract_description(body)
    {body, fields} = extract_fields(body)
    {body, effects} = extract_effects(body)

    # Generate moduledoc based on description
    moduledoc = generate_moduledoc(desc)

    # Gather metadata
    internal_metadata = %{
      name: full_name,
      description: desc,
      fields: fields,
      effects: effects,
      in_ports: in_ports,
      out_ports: out_ports
    }

    # Create metadata struct
    component_metadata = struct(Skitter.Component.Metadata, internal_metadata)

    # Add default callbacks
    defaults = generate_default_callbacks(internal_metadata, body)

    # Transform macro calls inside body AST
    body = transform_component_callbacks(body, internal_metadata)

    # Check for errors
    errors = check_component_body(internal_metadata, body)

    quote generated: true do
      defmodule unquote(name) do
        @behaviour unquote(Skitter.Component)
        import unquote(Skitter.Component), only: []

        import unquote(__MODULE__),
          only: [
            react: 3,
            init: 3,
            terminate: 2,
            checkpoint: 2,
            restore: 3,
            clean_checkpoint: 3
          ]

        @moduledoc unquote(moduledoc)

        def __skitter_metadata__, do: unquote(Macro.escape(component_metadata))

        unquote(body)
        unquote(errors)
        unquote(defaults)
      end
    end
  end

  # AST Transformations
  # -------------------
  # Transformations applied to the body provided to component/3

  # Extract effect declarations from the AST and add the effects to the effect
  # list.
  # Effects are specified as either:
  #  effect effect_name property1, property2
  #  effect effect_name
  # In both cases, the full statement will be removed from the ast, and the
  # effect will be added to the accumulator with its properties.
  defp extract_effects(body) do
    Macro.postwalk(body, [], fn
      {:effect, _env, [effect]}, acc ->
        {effect, properties} = Macro.decompose_call(effect)

        properties =
          Enum.map(properties, fn
            {name, _env, _args} -> name
            any -> {:error, any}
          end)

        {nil, Keyword.put(acc, effect, properties)}

      any, acc ->
        {any, acc}
    end)
  end

  # Find field declarations in the AST and transform them into a defstruct.
  # Return the list of fields to the caller. If there are multiple field
  # statements, add an error.
  defp extract_fields(body) do
    Macro.postwalk(body, nil, fn
      {:fields, _env, fields}, nil ->
        fields =
          Enum.map(fields, fn
            {name, _env, atom} when is_atom(atom) -> name
            any -> {:error, any}
          end)

        {
          quote do
            defstruct unquote(fields)
          end,
          fields
        }

      {:fields, _env, _args}, _fields ->
        {nil, :error}

      any, acc ->
        {any, acc}
    end)
  end

  # Inject the component metadata into all macro calls which are present in any
  # of the component_callback attribute lists.
  # Depending on the exact lists which a callback is in, the remainder of the
  # arguments should be modified.
  #
  # This function is also responsible for modifying all calls to helper into
  # calls to defp
  defp transform_component_callbacks(body, meta) do
    Macro.postwalk(body, fn
      # Wrap an arbitrary amount of arguments into a list: `foo(a, b)` becomes
      # `foo([a,b])`. This makes it possible to specify an arbitrary amount of
      # arguments
      {name, env, arg_lst} when name in @component_callbacks_arglst ->
        {args, [block]} = Enum.split(arg_lst, -1)
        {name, env, [args, meta, block]}

      # Don't accept any args besides the body
      {name, env, [block]} when name in @component_callbacks_no_args ->
        {name, env, [meta, block]}

      # Accept a single argument, which remains unchanged
      {name, env, [arg, block]} when name in @component_callbacks_single_arg ->
        {name, env, [arg, meta, block]}

      {:helper, env, rest} ->
        {:defp, env, rest}

      any ->
        any
    end)
  end

  # Retrieve the description from a component if it is present.
  # A description is provided when the component body start with a string.
  # If this is the case, remove the string from the body and use it as the
  # component description.
  # If it is not the case, leave the component body untouched.
  defp extract_description({:__block__, env, [str | r]}) when is_binary(str) do
    {{:__block__, env, r}, str}
  end

  defp extract_description(str) when is_binary(str),
    do:
      {quote generated: true do
       end, str}

  defp extract_description(any), do: {any, ""}

  # Utility Functions
  # -----------------
  # Functions used when expanding the component/3 macro

  # Generate a readable string (i.e. a string with spaces) based on the name
  # of a component.
  defp module_name_to_snake_case(name) do
    name = name |> Atom.to_string() |> String.split(".") |> Enum.at(-1)
    rgxp = ~r/([[:upper:]]+(?=[[:upper:]]|$)|[[:upper:]][[:lower:]]*|\d+)/
    rgxp |> Regex.replace(name, " \\0") |> String.trim()
  end

  defp generate_moduledoc(""), do: false

  defp generate_moduledoc(desc) do
    """
      #{desc}

      _This moduledoc of this component was automatically generated by_
      _`Skitter.Component.DSL`_.
    """
  end

  # Parse the port lists, add an empty list for out ports if they are not
  # provided
  defp read_ports(in: in_ports), do: read_ports(in: in_ports, out: [])

  defp read_ports(in: in_ports, out: out_ports) do
    {parse_port_names(in_ports), parse_port_names(out_ports)}
  end

  # Parse the various ports names encountered in the port list.
  defp parse_port_names(lst) when is_list(lst) do
    Enum.map(lst, &transform_port_name/1)
  end

  # Allow single names to be specified outside of a list
  #   e.g. in: foo will become in: [foo]
  # Leave the actual parsing up to the list variant of this function.
  defp parse_port_names(el), do: parse_port_names([el])

  # Default Generation
  # ------------------

  # Default implementations of various skitter functions
  # We cannot use defoverridable, as the compiler will remove it before
  # the init, react, ... macros are expanded.
  defp generate_default_callbacks(meta, body) do
    # We cannot store callbacks in attributes, so we store them in a map here.
    defaults = %{
      init: &default_init/1,
      terminate: &default_terminate/1,
      checkpoint: &default_checkpoint/1,
      restore: &default_restore/1,
      clean_checkpoint: &defaul_clean_checkpoint/1
    }

    Enum.map(@default_callbacks, fn name ->
      if count_occurrences(name, body) >= 1 do
        nil
      else
        defaults[name].(meta)
      end
    end)
  end

  defp default_init(_) do
    quote generated: true do
      def __skitter_init__(_), do: {:ok, nil}
    end
  end

  defp default_terminate(_) do
    quote generated: true do
      def __skitter_terminate__(_), do: :ok
    end
  end

  defp default_checkpoint(_) do
    quote generated: true do
      def __skitter_checkpoint__(_), do: :nocheckpoint
    end
  end

  defp default_restore(_) do
    quote generated: true do
      def __skitter_restore__(_), do: :nocheckpoint
    end
  end

  defp defaul_clean_checkpoint(meta) do
    required = :hidden in Keyword.get(meta.effects, :state_change, [])
    res = if required, do: :ok, else: :nocheckpoint

    quote generated: true do
      def __skitter_clean_checkpoint__(_), do: unquote(res)
    end
  end

  # Error Checking
  # --------------
  # Functions that check if the component as a whole is correct

  defp check_component_body(meta, body) do
    [
      check_fields(meta),
      check_effects(meta),
      check_react(meta, body),
      check_checkpoint(meta, body),
      check_port_names(meta.in_ports),
      check_port_names(meta.out_ports)
    ]
  end

  # Ensure all ports are valid.
  # Errors are already flagged by the port names parser, just extract them here.
  defp check_port_names(list) do
    case Enum.find(list, &match?({:error, _}, &1)) do
      {:error, val} ->
        inject_error "`#{val}` is not a valid port"

      nil ->
        nil
    end
  end

  # Check if the specified effects are valid.
  # If they are, ensure their properties are valid as well.
  defp check_effects(metadata) do
    for {effect, properties} <- metadata.effects do
      with valid when valid != nil <- Keyword.get(@valid_effects, effect),
           [] <- Enum.reject(properties, fn p -> p in valid end) do
        nil
      else
        nil ->
          inject_error "Effect `#{effect}` is not valid"

        [{:error, prop} | _] ->
          inject_error "`#{prop}` is not a valid property"

        [prop | _] ->
          inject_error "`#{prop}` is not a valid property of `#{effect}`"
      end
    end
  end

  # Handle the errors returned by `extract_fields/1`
  defp check_fields(metadata) do
    case metadata.fields do
      nil ->
        nil

      :error ->
        inject_error "Fields can only be defined once."

      lst when is_list(lst) ->
        Enum.map(lst, fn
          {:error, any} -> inject_error "`#{any}` is not a valid field"
          _ -> nil
        end)
    end
  end

  # Ensure react is present in the component
  defp check_react(meta, body) do
    unless count_occurrences(:react, body) >= 1 do
      inject_error "Component `#{meta.name}` lacks a react implementation"
    end
  end

  # Ensure checkpoint and restore are present if the component manages its own
  # internal state. If it does not, ensure they are not present.
  defp check_checkpoint(meta, body) do
    required = :hidden in Keyword.get(meta.effects, :state_change, [])
    cp_present = count_occurrences(:checkpoint, body) >= 1
    rt_present = count_occurrences(:restore, body) >= 1
    cl_present = count_occurrences(:clean_checkpoint, body) >= 1
    either_present = cp_present or rt_present or cl_present
    both_present = cp_present and rt_present

    case {required, either_present, both_present} do
      {true, _, true} ->
        nil

      {false, false, _} ->
        nil

      {true, _, false} ->
        inject_error "`checkpoint` and `restore` are required when the " <>
                       "state change is hidden"

      {false, true, _} ->
        inject_error "`checkpoint`, `restore` and `clean_checkpoint` are " <>
                       "only allowed when the state change is hidden"
    end
  end

  # ------------- #
  # Shared Macros #
  # ------------- #
  # Macros which are usable inside multiple callbacks inside component.

  @doc """
  Fetch the current component instance.

  Usable inside `react/3`, `init/3`.
  """
  defmacro instance do
    quote generated: true do
      var!(skitter_instance)
    end
  end

  @doc """
  Modify the instance of the component.

  Usable inside `init/3`, and inside `react/3` iff the component is marked
  with the `:state_change` effect.
  """
  defmacro instance!(value) do
    quote generated: true do
      var!(skitter_instance) = unquote(value)
    end
  end

  @doc """
  Stop the current callback and return with an error.

  A reason should be provided as a string. In certain contexts (e.g. `init/3`),
  the use of this macro will crash the entire workflow.
  """
  defmacro error(reason) do
    quote generated: true do
      throw {:skitter_error, unquote(reason)}
    end
  end

  # --------------- #
  # Init Generation #
  # --------------- #

  @doc """
  Instantiate a skitter component.

  This macro will generate the code that will instantiate the skitter component.
  You should use `instance!/1` inside this macro to return a valid instance.

  Besides the body, this callback accepts a single argument, which can be used
  to pattern match on the user-provided input this callback will receive.

  ## Example

  ```
  init [foo, bar] do
    instance! foo + bar
  end
  ```

  Can be called as: `Skitter.Component.init(ComponentName, [1,2])`
  """
  defmacro init(args, _meta, do: body) do
    error =
      use_or_error(
        body,
        :instance!,
        "`init` needs to return a component instance using `instance!`"
      )

    body =
      quote generated: true do
        import unquote(__MODULE__), only: [instance!: 1, error: 1]
        unquote(body)
        {:ok, var!(skitter_instance)}
      end

    body = add_skitter_error_handler(body)

    quote generated: true do
      unquote(error)

      def __skitter_init__(unquote(args)) do
        unquote(body)
      end
    end
  end

  # -------------------- #
  # Terminate Generation #
  # -------------------- #

  @doc """
  Generate component cleanup code.

  This macro can be used to cleanup any resources before a component is shut
  down. `instance/0` can be used in the body of this macro if data from the
  current instance is needed.
  """
  defmacro terminate(_meta, do: body) do
    instance_count = count_occurrences(:instance, body)

    instance_arg =
      if instance_count >= 1 do
        quote generated: true do
          var!(skitter_instance)
        end
      else
        quote generated: true do
          _
        end
      end

    body =
      quote generated: true do
        import unquote(__MODULE__), only: [instance: 0, error: 1]
        unquote(body)
        :ok
      end

    body = body |> transform_instance() |> add_skitter_error_handler()

    quote generated: true do
      def __skitter_terminate__(unquote(instance_arg)) do
        unquote(body)
      end
    end
  end

  # --------------------- #
  # Checkpoint Generation #
  # --------------------- #

  @doc """
  Create a checkpoint.

  _Use as `checkpoint do ... end`, `instance/0` and `instance!/1` are usable
  inside of the body of checkpoint._

  Use this macro to automatically generate the code for creating a checkpoint.
  The current instance can be obtained inside this checkpoint, through the use
  of `instance/0`. The body is required to return a checkpoint by using
  `checkpoint!/1`.
  """
  defmacro checkpoint(_meta, do: body) do
    instance_count = count_occurrences(:instance, body)

    instance_arg =
      if instance_count >= 1 do
        quote generated: true do
          var!(skitter_instance)
        end
      else
        quote generated: true do
          _
        end
      end

    body = transform_instance(body)

    error =
      use_or_error(
        body,
        :checkpoint!,
        "`checkpoint` needs to return a checkpoint using `checkpoint!`"
      )

    quote generated: true do
      unquote(error)

      def __skitter_checkpoint__(unquote(instance_arg)) do
        import unquote(__MODULE__), only: [instance: 0, checkpoint!: 1]
        unquote(body)
        {:ok, var!(skitter_checkpoint)}
      end
    end
  end

  @doc """
  Update the current return value of checkpoint.

  Using this macro multiple times will overwrite the previous value.
  """
  defmacro checkpoint!(value) do
    quote generated: true do
      var!(skitter_checkpoint) = unquote(value)
    end
  end

  # ------------------ #
  # Restore Generation #
  # ------------------ #

  @doc """
  Restore a component instance from a checkpoint.

  This macro is almost identical to `init/3`. It accepts a checkpoint, provided
  by `checkpoint/2` as its only input argument. Just like `init/3`, it is
  required to return an instance through the use of `instance!/1`.
  """
  defmacro restore(args, _meta, do: body) do
    error =
      use_or_error(
        body,
        :instance!,
        "`restore` needs to return a component instance using `instance!`"
      )

    quote generated: true do
      unquote(error)

      def __skitter_restore__(unquote(args)) do
        import unquote(__MODULE__), only: [instance!: 1, error: 1]
        unquote(body)
        {:ok, var!(skitter_instance)}
      end
    end
  end

  # --------------------------- #
  # Clean Checkpoint Generation #
  # --------------------------- #

  @doc """
  Clean up an existing checkpoint.

  Skitter calls this macro when it will not use a certain checkpoint anymore.
  This checkpoint is passed as the only input argument to the macro.
  The body of the macro is responsible for cleaning up any resources associated
  with this particular checkpoint.
  """
  defmacro clean_checkpoint(args, _meta, do: body) do
    quote generated: true do
      def __skitter_clean_checkpoint__(unquote(args)) do
        unquote(body)
        :ok
      end
    end
  end

  # ---------------- #
  # React Generation #
  # ---------------- #

  @doc """
  React to incoming data.

  React to incoming data from the in ports. Every in port of the component
  should have a matching parameter in the "header" of react.
  For instance, if a component has two in ports: `foo`, and `bar`, the
  react of that component should start as follows: `react foo, bar do ...`
  The names of the parameters can be freely chosen and pattern matching is
  possible. Elixir guards cannot be used though.

  Inside the body of react, `spit/2` can be used to send data to output ports,
  `instance/0` can be used to obtain the value of the current instance. If the
  component has an internal state, `instance!` can be used to update the
  current instance.
  """
  defmacro react(args, meta, do: body) do
    body = body |> transform_spit() |> transform_instance()
    errors = check_react_body(args, meta, body)

    react_body = remove_after_failure(body)
    react_after_failure_body = build_react_after_failure_body(body, meta)

    {react_body, react_arg} = create_react_body_and_arg(react_body)
    {fail_body, fail_arg} = create_react_body_and_arg(react_after_failure_body)

    quote generated: true do
      unquote(errors)

      def __skitter_react__(unquote(react_arg), unquote(args)) do
        unquote(react_body)
      end

      def __skitter_react_after_failure__(unquote(fail_arg), unquote(args)) do
        unquote(fail_body)
      end
    end
  end

  # Internal Macros
  # ---------------

  @doc """
  Provide a value to the workflow on a given port.

  The given value will be sent to every other component that is connected to
  the provided output port of the component.
  The value will be sent _after_ `react/3` has finished executing.

  Usable inside `react/3` iff the component has an output port.
  """
  defmacro spit(port, value) do
    quote generated: true do
      var!(skitter_output) =
        Keyword.put(
          var!(skitter_output),
          unquote(port),
          unquote(value)
        )
    end
  end

  @doc """
  Code that should only be executed after a failure occurred.

  _Usable inside `react/3` iff the component has an external state._

  The code in this block will only be executed if `react/3` is triggered
  after a failure occurred. Internally, this operation is a no-op. Post walks
  will filter out calls to this macro when needed.

  This block is mainly meant to provide clean up code in case a component
  experiences some form of failure. For instance, if a call to react can
  produce some side effect, this block can check if that side effect already
  occurred before deciding whether or not execution should proceed.

  ## Example

  For instance, let's look at the following react function, which writes a
  value to some database after which it sends it to an output port.

  ```
  react val do
    write_to_db(val)
    spit val ~> port
  end
  ```

  The skitter runtime would have no way of knowing whether or not the database
  was updated if this component would fail in the middle of a call to `react`.
  However, in order to ensure the remainder of the workflow is still activated
  correctly, the value sent to `port` is needed.

  To solve this problem, we can use the `after_failure` block:

  ```
  react val do
    after_failure do
      if write_to_db_occurred?(val) do
        spit val ~> port
        skip
      end
    end

    write_to_db(val)
    spit val ~> port
  end
  ```

  The after_failure block will only be executed if a previous call to `react`
  failed. In this case, it would check if the database was updated. If this
  is the case, it sends the value to `port` and it uses `skip/2` to ensure
  the remainder of `react` is not carried out.
  """
  defmacro after_failure(do: body), do: body

  @doc """
  Stop the execution of react, and return the current instance and spits.

  Using this macro will automatically stop the execution of react. Unlike the
  use of `error/1`, any changes made to the instance (through `instance!/1`)
  and any values provided to `spit/2` will still be returned to the skitter
  runtime.

  This macro is useful when the execution of react should only continue under
  certain conditions. It is especially useful in an `after_failure/1` body, as
  it can be used to only continue the execution of react if no effect occurred
  in the original call to react.

  Do not call this manually, as the `instance` and `output` arguments are
  provided by macro expansion code in `react/3`.
  """
  defmacro skip(instance, output) do
    quote generated: true do
      throw {:skitter_skip, unquote(instance), unquote(output)}
    end
  end

  # AST Creation
  # ------------

  # Create the AST which will become the body of react. Besides this, generate
  # the arguments for the react function header.
  # This needs to happen to ensure that var! can be injected into the argument
  # list of the function header if needed.
  defp create_react_body_and_arg(body) do
    {out_pre, out_post} = create_react_output(body)
    {inst_arg, inst_pre, inst_post} = create_react_instance(body)

    body =
      quote generated: true do
        import unquote(__MODULE__),
          only: [
            spit: 2,
            skip: 2,
            instance: 0,
            instance!: 1,
            error: 1,
            after_failure: 1
          ]

        unquote(inst_pre)
        unquote(out_pre)
        unquote(body)
        {:ok, unquote(inst_post), unquote(out_post)}
      end

    body = add_skip_handler(body, inst_post, out_post)
    body = add_skitter_error_handler(body)

    {body, inst_arg}
  end

  # Generate the ASTs for creating the initial value and reading the value
  # of skitter_output.
  defp create_react_output(body) do
    spit_use_count = count_occurrences(:spit, body)

    if spit_use_count > 0 do
      {
        quote generated: true do
          var!(skitter_output) = []
        end,
        quote generated: true do
          var!(skitter_output)
        end
      }
    else
      {nil, []}
    end
  end

  # Create the AST which manages the __skitter_instance__ variable throughout
  # the call to __skitter_react__ and __skitter_react_after_failure.
  # The following 3 ASTs are created:
  #   - The AST which will be injected into the react signature, this way, the
  #     skitter instance can be ignored if it is not used.
  #   - The AST which initializes the skitter instance variable.
  #   - The AST which provides the value that will be returned to the skitter
  #     runtime.
  defp create_react_instance(body) do
    read_count = count_occurrences(:instance, body)
    write_count = count_occurrences(:instance!, body)

    arg =
      if read_count > 0 do
        quote generated: true, do: var!(instance_arg)
      else
        quote generated: true, do: _instance_arg
      end

    pre =
      if read_count > 0 do
        quote generated: true, do: var!(skitter_instance) = var!(instance_arg)
      else
        nil
      end

    post =
      if write_count > 0 do
        quote generated: true, do: var!(skitter_instance)
      else
        nil
      end

    {arg, pre, post}
  end

  # Create the body of __skitter_react_after_failure based on the effects of
  # the component.
  #   - If the component has external effects, include the after_failure body
  #   - If the component has no external effects, generated the same code as
  #     in __skitter_react__. This makes it possible to simplify the skitter
  #     runtime code.
  defp build_react_after_failure_body(body, meta) do
    if Keyword.has_key?(meta.effects, :external_effect) do
      quote generated: true do
        unquote(body)
      end
    else
      remove_after_failure(body)
    end
  end

  # Add a handler for `skip`, if it is used. If it's not, this just returns the
  # body unchanged.
  # Skip is implemented through the use of a throw. It will simply throw the
  # current values for skitter_instance and skitter_output and return them as
  # the result of the block as a whole.
  # The quoted code for instance and output are provided by
  # `create_react_body_and_arg` to avoid code duplication.
  defp add_skip_handler(body, inst, out) do
    if count_occurrences(:skip, body) >= 1 do
      body =
        Macro.postwalk(body, fn
          {:skip, env, []} -> {:skip, env, [inst, out]}
          {:skip, env, atom} when is_atom(atom) -> {:skip, env, [inst, out]}
          any -> any
        end)

      quote generated: true do
        try do
          unquote(body)
        catch
          {:skitter_skip, instance, output} -> {:ok, instance, output}
        end
      end
    else
      body
    end
  end

  # AST Transformations
  # -------------------

  # Remove all `after_failure` blocks from the body
  defp remove_after_failure(body) do
    Macro.postwalk(body, fn
      {:after_failure, _env, _args} -> nil
      any -> any
    end)
  end

  # Transform all spit calls in the body:
  #   spit 5 + 2 -> port becomes spit :port, 5 + 2
  defp transform_spit(body) do
    Macro.postwalk(body, fn
      {:spit, env, [{:~>, _ae, [body, port = {_name, _pe, _pargs}]}]} ->
        {:spit, env, [transform_port_name(port), body]}

      any ->
        any
    end)
  end

  # Error Checking
  # --------------

  # Check the body of react for some common errors.
  defp check_react_body(args, meta, body) do
    cond do
      # Ensure the inputs can map to the provided argument list
      length(args) != length(meta.in_ports) ->
        inject_error "Different amount of arguments and in_ports"

      # Ensure all spits are valid
      (p = check_spits(meta.out_ports, body)) != nil ->
        inject_error "Port `#{p}` not in out_ports"

      # Ensure after_failure is only used when there are external effects
      count_occurrences(:after_failure, body) > 0 and
          !Keyword.has_key?(meta.effects, :external_effect) ->
        inject_error(
          "`after_failure` only allowed when external_effect is present"
        )

      # Ensure instance! is only used when there is an internal state
      count_occurrences(:instance!, body) > 0 and
          !Keyword.has_key?(meta.effects, :state_change) ->
        inject_error(
          "`instance!` only allowed when the state_change effect is present"
        )

      # Fallback case, no errors
      true ->
        nil
    end
  end

  # Check the spits in the body of react through `port_check_postwalk/2`
  # Verify that:
  #   - no errors occured when parsing port names
  #   - The output port is present in the output port list
  defp check_spits(ports, body) do
    {_, {_ports, port}} =
      Macro.postwalk(body, {ports, nil}, fn
        ast = {:spit, _env, [{:error, port}, _val]}, {ports, nil} ->
          {ast, {ports, port}}

        ast = {:spit, _env, [port, _val]}, {ports, nil} ->
          if port in ports, do: {ast, {ports, nil}}, else: {ast, {ports, port}}

        ast, acc ->
          {ast, acc}
      end)

    port
  end
end
