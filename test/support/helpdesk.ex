defmodule AshSmithy.Test.Helpdesk do
  @moduledoc false
  use Ash.Domain, extensions: [AshSmithy.Domain], validate_config_inclusion?: false

  smithy do
    namespace "com.example.helpdesk"
    version "2026-10-01"
    title "Helpdesk Service"
  end

  resources do
    resource AshSmithy.Test.Helpdesk.Ticket
    resource AshSmithy.Test.Helpdesk.Representative
    resource AshSmithy.Test.Helpdesk.Widget
  end
end

defmodule AshSmithy.Test.Helpdesk.Priority do
  @moduledoc false
  use Ash.Type.Enum, values: [:low, :medium, :high]
end

defmodule AshSmithy.Test.Helpdesk.Address do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, public?: true, allow_nil?: false
    attribute :city, :string, public?: true
  end
end

defmodule AshSmithy.Test.Helpdesk.Representative do
  @moduledoc false
  use Ash.Resource,
    domain: AshSmithy.Test.Helpdesk,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshSmithy.Resource]

  smithy do
    relationships([:tickets])

    operations do
      create :create
      read :read
      list :read, paginated?: false
    end
  end

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:name, :address]]
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, public?: true, allow_nil?: false, constraints: [max_length: 100]
    attribute :address, AshSmithy.Test.Helpdesk.Address, public?: true
  end

  relationships do
    has_many :tickets, AshSmithy.Test.Helpdesk.Ticket, public?: true
  end
end

defmodule AshSmithy.Test.Helpdesk.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshSmithy.Test.Helpdesk,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshSmithy.Resource]

  resource do
    description "A support ticket."
  end

  smithy do
    fields [
      :id,
      :subject,
      :body,
      :status,
      :priority,
      :tags,
      :estimate,
      :inserted_at,
      :subject_length,
      :representative_id
    ]

    relationships([:representative])

    operations do
      create :open
      read :read
      update :update
      delete :destroy, idempotent?: true
      list :read
      operation :close
      collection_operation :search
      collection_operation :count_open, method: "GET", readonly?: true
    end
  end

  ets do
    private? true
  end

  actions do
    destroy :destroy do
      primary? true
      require_atomic? false
      metadata :destroyed_subject, :string, allow_nil?: false

      change after_action(fn _changeset, record, _context ->
               {:ok, Ash.Resource.put_metadata(record, :destroyed_subject, record.subject)}
             end)
    end

    read :read do
      primary? true
      pagination keyset?: true, required?: false, default_limit: 25, max_page_size: 100
    end

    create :open do
      description "Open a new ticket."
      accept [:subject, :body, :priority, :tags, :estimate, :representative_id]

      argument :notify?, :boolean, default: false

      metadata :notified, :boolean, allow_nil?: false, description: "Whether anyone was notified."

      change after_action(fn changeset, record, _context ->
               notified = Ash.Changeset.get_argument(changeset, :notify?)
               {:ok, Ash.Resource.put_metadata(record, :notified, notified)}
             end)
    end

    update :update do
      accept [:subject, :body, :priority, :tags]
    end

    update :close do
      accept []
      change set_attribute(:status, :closed)
    end

    read :search do
      argument :query, :string, allow_nil?: false
      filter expr(contains(subject, ^arg(:query)))

      metadata :match_position, :integer, allow_nil?: false

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn query, results ->
          term = Ash.Query.get_argument(query, :query)

          {:ok,
           Enum.map(results, fn result ->
             {position, _} = :binary.match(result.subject, term)
             Ash.Resource.put_metadata(result, :match_position, position)
           end)}
        end)
      end

      pagination keyset?: true, offset?: true, required?: false
    end

    action :count_open, :integer do
      run fn _input, _context ->
        require Ash.Query

        {:ok,
         __MODULE__
         |> Ash.Query.filter(status == :open)
         |> Ash.count!(authorize?: false)}
      end
    end
  end

  preparations do
    prepare build(sort: [inserted_at: :asc])
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :subject, :string,
      public?: true,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 200]

    attribute :body, :string, public?: true

    attribute :status, :atom,
      public?: true,
      allow_nil?: false,
      default: :open,
      constraints: [one_of: [:open, :closed]]

    attribute :priority, AshSmithy.Test.Helpdesk.Priority, public?: true, default: :medium
    attribute :tags, {:array, :string}, public?: true, default: []
    attribute :estimate, :decimal, public?: true
    attribute :secret, :string

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :representative, AshSmithy.Test.Helpdesk.Representative,
      public?: true,
      attribute_public?: true
  end

  calculations do
    calculate :subject_length, :integer, expr(string_length(subject)), public?: true
  end
end

defmodule AshSmithy.Test.Helpdesk.Widget do
  @moduledoc false
  use Ash.Resource,
    domain: AshSmithy.Test.Helpdesk,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshSmithy.Resource]

  smithy do
    operations do
      create :create
      read :read_with_length
      update :update
      list :read_with_length, paginated?: false
      operation :rename
      operation :lookup
      collection_operation :featured
    end
  end

  ets do
    private? true
  end

  actions do
    defaults [:read, create: :*]

    read :read_with_length do
      metadata :name_length, :integer

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, results ->
          {:ok,
           Enum.map(results, &Ash.Resource.put_metadata(&1, :name_length, String.length(&1.name)))}
        end)
      end
    end

    update :update do
      accept [:name, :content, :dimensions, :addresses]
      argument :reason, :string
      # Atomic updates of union attributes currently fail with the ETS data layer
      require_atomic? false
    end

    update :rename do
      accept [:name]
    end

    read :lookup do
      get? true
      argument :include_archived, :boolean, default: false
    end

    action :featured, :struct do
      constraints instance_of: __MODULE__

      run fn _input, _context ->
        {:ok, %__MODULE__{id: 1, name: "featured"}}
      end
    end
  end

  attributes do
    attribute :id, :integer,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: fn -> System.unique_integer([:positive]) end

    attribute :name, :string, public?: true, allow_nil?: false

    attribute :content, :union,
      public?: true,
      constraints: [
        types: [
          text: [type: :string],
          number: [type: :integer],
          address: [type: AshSmithy.Test.Helpdesk.Address]
        ]
      ]

    attribute :dimensions, :map,
      public?: true,
      constraints: [
        fields: [
          width: [type: :float, allow_nil?: false],
          height: [type: :float, allow_nil?: false],
          unit: [type: :atom, constraints: [one_of: [:cm, :in]]]
        ]
      ]

    attribute :addresses, {:array, AshSmithy.Test.Helpdesk.Address}, public?: true
    attribute :settings, :map, public?: true
  end
end
