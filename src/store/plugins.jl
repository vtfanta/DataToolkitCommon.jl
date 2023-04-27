const STORE_GC_CONFIG_INFO = """
Four (system-wide) settings determine garbage collection behaviour:
1. `auto_gc` (default $(DEFAULT_INVENTORY_CONFIG.auto_gc)): How often to
   automatically run garbage collection (in hours). Set to a non-positive value
   to disable.
2. `max_age` (default $(DEFAULT_INVENTORY_CONFIG.max_age)): The maximum number
   of days since a collection was last seen before it is removed from
   consideration.
3. `max_size` (default $(DEFAULT_INVENTORY_CONFIG.max_size)): The maximum
   (total) size of the store.
4. `recency_beta` (default $(DEFAULT_INVENTORY_CONFIG.recency_beta)): When
   removing items to avoid going over `max_size`, how much recency should be
   valued. Can be set to any value in (-∞, ∞). Larger (positive) values weight
   recency more, and negative values weight size more. -1 and 1 are equivalent.
"""

"""
Cache IO from data storage backends, by saving the contents to the disk.

## Configuration

#### Disabling on a per-storage basis

Saving of individual storage sources can be disabled by setting the "save"
parameter to `false`, i.e.

```toml
[[somedata.storage]]
save = false
```

#### Checksums

To ensure data integrity, a checksum can be specified, and checked when saving
to the store. For example,

```
[[iris.storage]]
checksum = "crc32c:f7ae7e64"
```

If you do not have a checksum, but wish for one to be calculated upon accessing
the data, the checksum parameter can be set to the special value `"auto"`. When
the data is first accessed, a checksum will be generated and replace the "auto"
value.

To explicitly specify no checksum, set the parameter to `false`.

System-wide configuration can be set via the `store config set` REPL command, or
directly modifying the `$(@__MODULE__).INVENTORY.config` struct.

$STORE_GC_CONFIG_INFO
"""
const STORE_PLUGIN = Plugin("store", [
    function (post::Function, f::typeof(storage), storer::DataStorage, as::Type; write::Bool)
        global INVENTORY
        # Get any applicable cache file
        update_inventory!()
        source = getsource(storer)
        file = storefile(storer)
        if !shouldstore(storer) || write
            # If the store is invalid (should not be stored, or about to be
            # written to), then it should be removed before proceeding as
            # normal.
            if !isnothing(source)
                index = findfirst(==(source), INVENTORY.stores)
                !isnothing(index) && deleteat!(INVENTORY.stores, index)
                write(INVENTORY)
            end
            (post, f, (storer, as), (; write))
        elseif !isnothing(file) && isfile(file)
            # If using a cache file, ensure the parent collection is registered
            # as a reference.
            update_source!(source, storer)
            if as === IO || as === IOStream
                if should_log_event("store", storer)
                    @info "Opening $as for $(sprint(show, storer.dataset.name)) from the store"
                end
                (post, identity, (open(file, "r"),))
            elseif as === FilePath
                (post, identity, (FilePath(file),))
            else
                (post, f, (storer, as), (; write))
            end
        elseif as == IO || as == IOStream
            # Try to get it as a file, because that avoids
            # some potential memory issues (e.g. large downloads
            # which exceed memory limits).
            tryfile = storage(storer, FilePath; write)
            if !isnothing(tryfile)
                io = open(storesave(storer, FilePath, tryfile), "r")
                (post, identity, (io,))
            else
                (post ∘ storesave(storer, as), f, (storer, as), (; write))
            end
        elseif as === FilePath
            (post ∘ storesave(storer, as), f, (storer, as), (; write))
        else
            (post, f, (storer, as), (; write))
        end
    end,
    function (post::Function, f::typeof(rhash), storage::DataStorage, parameters::SmallDict, h::UInt)
        delete!(parameters, "save") # Does not impact the final result
        (post, f, (storage, parameters, h))
    end])

"""
Cache the results of data loaders using the `Serialisation` standard library. Cache keys
are determined by the loader "recipe" and the type requested.

It is important to note that not all data types can be cached effectively, such
as an `IOStream`.

## Recipe hashing

The driver, parameters, type(s), of a loader and the storage drivers of a dataset
are all combined into the "recipe hash" of a loader.

```
╭─────────╮             ╭──────╮
│ Storage │             │ Type │
╰───┬─────╯             ╰───┬──╯
    │    ╭╌╌╌╌╌╌╌╌╌╮    ╭───┴────╮ ╭────────╮
    ├╌╌╌╌┤ DataSet ├╌╌╌╌┤ Loader ├─┤ Driver │
    │    ╰╌╌╌╌╌╌╌╌╌╯    ╰───┬────╯ ╰────────╯
╭───┴─────╮             ╭───┴───────╮
│ Storage ├─╼           │ Parmeters ├─╼
╰─────┬───╯             ╰───────┬───╯
      ╽                         ╽
```

Since the parameters of the loader (and each storage backend) can reference
other data sets (indicated with `╼` and `╽`), this hash is computed recursively,
forming a Merkle Tree. In this manner the entire "recipe" leading to the final
result is hashed.

```
                ╭───╮
                │ E │
        ╭───╮   ╰─┬─╯
        │ B ├──▶──┤
╭───╮   ╰─┬─╯   ╭─┴─╮
│ A ├──▶──┤     │ D │
╰───╯   ╭─┴─╮   ╰───╯
        │ C ├──▶──┐
        ╰───╯   ╭─┴─╮
                │ D │
                ╰───╯
```

In this example, the hash for a loader of data set "A" relies on the data sets
"B" and "C", and so their hashes are calculated and included. "D" is required by
both "B" and "C", and so is included in each. "E" is also used in "D".

## Configuration

Caching of individual loaders can be disabled by setting the "cache" parameter
to `false`, i.e.

```toml
[[somedata.loader]]
cache = false
...
```

System-wide configuration can be set via the `store config set` REPL command, or
directly modifying the `$(@__MODULE__).INVENTORY.config` struct.

$STORE_GC_CONFIG_INFO
"""
const CACHE_PLUGIN = Plugin("cache", [
    function (post::Function, f::typeof(load), loader::DataLoader, source::Any, as::Type)
        if shouldstore(loader, as)
            # Get any applicable cache file
            update_inventory!()
            cache = getsource(loader, as)
            file = storefile(cache)
            # Ensure all needed packages are loaded, and all relevant
            # types have the same structure, before loading.
            if !isnothing(file)
                for pkg in cache.packages
                    DataToolkitBase.get_package(pkg)
                end
                if !all(@. rhash(typeify(first(cache.types))) == last(cache.types))
                    file = nothing
                end
            end
            if !isnothing(file) && isfile(file)
                if should_log_event("cache", loader)
                    @info "Loading $as form of $(sprint(show, loader.dataset.name)) from the store"
                end
                update_source!(cache, loader)
                info = Base.invokelatest(deserialize, file)
                (post, identity, (info,))
            else
                (post ∘ storesave(loader), f, (loader, source, as))
            end
        else
            (post, f, (loader, source, as))
        end
    end,
    function (post::Function, f::typeof(rhash), loader::DataLoader, parameters::SmallDict, h::UInt)
        delete!(parameters, "cache") # Does not impact the final result
        (post, f, (loader, parameters, h))
    end])
