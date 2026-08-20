compiler=${1:?missing compiler executable}
shift

args=("$@")
override_root=
source_root=
compile_index=

for ((i = 0; i < ${#args[@]}; ++i)); do
  argument=${args[i]}
  case "$argument" in
    -iquote*brave/chromium_src)
      override_root=${argument#-iquote}
      source_root=${override_root%brave/chromium_src}
      ;;
  esac
  if [[ $argument == -c || $argument == /c ]]; then
    compile_index=$((i + 1))
  fi
done

if [[ -n $override_root && -n $compile_index && $compile_index -lt ${#args[@]} ]]; then
  source_file=${args[compile_index]}
  relative_source=

  if [[ $source_file == "$source_root"* ]]; then
    relative_source=${source_file#"$source_root"}
  elif [[ $source_file == gen/* ]]; then
    relative_source=${source_file#gen/}
  elif [[ $source_file == */gen/* ]]; then
    first_component=${source_file%%/*}
    remainder=${source_file#*/}
    if [[ $first_component != */* && $remainder == gen/* ]]; then
      relative_source=${remainder#gen/}
    fi
  fi

  if [[ -n $relative_source && -f $override_root/$relative_source ]]; then
    args[compile_index]="$override_root/$relative_source"
  fi
fi

exec "$compiler" "${args[@]}"
