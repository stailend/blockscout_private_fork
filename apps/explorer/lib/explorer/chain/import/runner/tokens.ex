defmodule Explorer.Chain.Import.Runner.Tokens do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.Token.t/0`.
  """
  use Utils.CompileTimeEnvHelper, bridged_tokens_enabled: [:explorer, [Explorer.Chain.BridgedToken, :enabled]]

  require Ecto.Query

  import Ecto.Query, only: [from: 2]

  alias Ecto.{Multi, Repo}
  alias Explorer.Chain.{Hash, Import, Token}
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [Token.t()]

  @type token_holder_count_delta :: %{contract_address_hash: Hash.Address.t(), delta: neg_integer() | pos_integer()}
  @type holder_count :: non_neg_integer()
  @type token_holder_count :: %{contract_address_hash: Hash.Address.t(), count: holder_count()}

  def update_holder_counts_with_deltas(repo, token_holder_count_deltas, %{
        timeout: timeout,
        timestamps: %{updated_at: updated_at}
      }) do
    {hashes, deltas} =
      token_holder_count_deltas
      |> Enum.map(fn %{contract_address_hash: contract_address_hash, delta: delta} ->
        {:ok, contract_address_hash_bytes} = Hash.Address.dump(contract_address_hash)
        {contract_address_hash_bytes, delta}
      end)
      |> Enum.unzip()

    token_query =
      from(
        token in Token,
        where: token.contract_address_hash in ^hashes,
        select: token.contract_address_hash,
        order_by: token.contract_address_hash,
        lock: "FOR NO KEY UPDATE"
      )

    query =
      from(
        token in Token,
        join:
          deltas in fragment(
            "(SELECT unnest(?::bytea[]) as contract_address_hash, unnest(?::bigint[]) as delta)",
            ^hashes,
            ^deltas
          ),
        on: token.contract_address_hash == deltas.contract_address_hash,
        where: token.contract_address_hash in subquery(token_query),
        where: not is_nil(token.holder_count),
        update: [
          set: [
            holder_count: token.holder_count + deltas.delta,
            updated_at: ^updated_at
          ]
        ],
        select: %{
          contract_address_hash: token.contract_address_hash,
          holder_count: token.holder_count
        }
      )

    {_total, result} = repo.update_all(query, [], timeout: timeout)

    {:ok, result}
  end

  @impl Import.Runner
  def ecto_schema_module, do: Token

  @impl Import.Runner
  def option_key, do: :tokens

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    multi
    |> Multi.run(:filter_token_params, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> filter_token_params(repo, changes_list) end,
        :block_referencing,
        :tokens,
        :filter_token_params
      )
    end)
    |> Multi.run(:tokens, fn repo, %{filter_token_params: filtered_changes_list} ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, filtered_changes_list, insert_options) end,
        :block_referencing,
        :tokens,
        :tokens
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{
          required(:on_conflict) => Import.Runner.on_conflict(),
          required(:timeout) => timeout(),
          required(:timestamps) => Import.timestamps()
        }) :: {:ok, [Token.t()]}
  def insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    ordered_changes_list =
      changes_list
      # brand new tokens start with no holders
      # set cataloged: nil, if not set before, to get proper COALESCE result
      # if don't set it, cataloged will default to false (as in DB schema)
      # and COALESCE in on_conflict will return false
      |> Stream.map(fn token -> token |> Map.put_new(:holder_count, 0) |> Map.put_new(:cataloged, nil) end)
      # Enforce Token ShareLocks order (see docs: sharelocks.md)
      |> Enum.sort_by(& &1.contract_address_hash)

    {:ok, _} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        conflict_target: :contract_address_hash,
        on_conflict: on_conflict,
        for: Token,
        returning: true,
        timeout: timeout,
        timestamps: timestamps
      )
  end

  defp filter_token_params(repo, changes_list) do
    existing_token_map =
      changes_list
      |> Enum.map(& &1[:contract_address_hash])
      |> Enum.uniq()
      |> Token.tokens_by_contract_address_hashes()
      |> repo.all()
      |> Map.new(&{&1.contract_address_hash, &1})

    filtered_tokens =
      Enum.filter(changes_list, fn token ->
        existing_token = existing_token_map[token[:contract_address_hash]]
        should_update?(token, existing_token)
      end)

    {:ok, filtered_tokens}
  end

  if @bridged_tokens_enabled do
    @fields_to_replace [:name, :symbol, :total_supply, :decimals, :type, :cataloged, :bridged, :skip_metadata]

    def default_on_conflict do
      from(
        token in Token,
        update: [
          set: [
            name: fragment("COALESCE(EXCLUDED.name, ?)", token.name),
            symbol: fragment("COALESCE(EXCLUDED.symbol, ?)", token.symbol),
            total_supply: fragment("COALESCE(EXCLUDED.total_supply, ?)", token.total_supply),
            decimals: fragment("COALESCE(EXCLUDED.decimals, ?)", token.decimals),
            type: fragment("COALESCE(EXCLUDED.type, ?)", token.type),
            cataloged: fragment("COALESCE(EXCLUDED.cataloged, ?)", token.cataloged),
            bridged: fragment("COALESCE(EXCLUDED.bridged, ?)", token.bridged),
            skip_metadata: fragment("COALESCE(EXCLUDED.skip_metadata, ?)", token.skip_metadata),
            # `holder_count` is not updated as a pre-existing token means the `holder_count` is already initialized OR
            #   need to be migrated with `priv/repo/migrations/scripts/update_new_tokens_holder_count_in_batches.sql.exs`
            # Don't update `contract_address_hash` as it is the primary key and used for the conflict target
            inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", token.inserted_at),
            updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", token.updated_at)
          ]
        ],
        where:
          fragment(
            "(EXCLUDED.name, EXCLUDED.symbol, EXCLUDED.total_supply, EXCLUDED.decimals, EXCLUDED.type, EXCLUDED.cataloged, EXCLUDED.bridged, EXCLUDED.skip_metadata) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?, ?)",
            token.name,
            token.symbol,
            token.total_supply,
            token.decimals,
            token.type,
            token.cataloged,
            token.bridged,
            token.skip_metadata
          )
      )
    end
  else
    @fields_to_replace [:name, :symbol, :total_supply, :decimals, :type, :cataloged, :skip_metadata]

    def default_on_conflict do
      from(
        token in Token,
        update: [
          set: [
            name: fragment("COALESCE(EXCLUDED.name, ?)", token.name),
            symbol: fragment("COALESCE(EXCLUDED.symbol, ?)", token.symbol),
            total_supply: fragment("COALESCE(EXCLUDED.total_supply, ?)", token.total_supply),
            decimals: fragment("COALESCE(EXCLUDED.decimals, ?)", token.decimals),
            type: fragment("COALESCE(EXCLUDED.type, ?)", token.type),
            cataloged: fragment("COALESCE(EXCLUDED.cataloged, ?)", token.cataloged),
            skip_metadata: fragment("COALESCE(EXCLUDED.skip_metadata, ?)", token.skip_metadata),
            # `holder_count` is not updated as a pre-existing token means the `holder_count` is already initialized OR
            #   need to be migrated with `priv/repo/migrations/scripts/update_new_tokens_holder_count_in_batches.sql.exs`
            # Don't update `contract_address_hash` as it is the primary key and used for the conflict target
            inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", token.inserted_at),
            updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", token.updated_at)
          ]
        ],
        where:
          fragment(
            "(EXCLUDED.name, EXCLUDED.symbol, EXCLUDED.total_supply, EXCLUDED.decimals, EXCLUDED.type, EXCLUDED.cataloged, EXCLUDED.skip_metadata) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?)",
            token.name,
            token.symbol,
            token.total_supply,
            token.decimals,
            token.type,
            token.cataloged,
            token.skip_metadata
          )
      )
    end
  end

  defp should_update?(_new_token, nil), do: true

  defp should_update?(new_token, existing_token) do
    new_token_params = Map.take(new_token, @fields_to_replace)

    Enum.reduce_while(new_token_params, false, fn {key, value}, _acc ->
      if Map.get(existing_token, key) == value do
        {:cont, false}
      else
        {:halt, true}
      end
    end)
  end
end
