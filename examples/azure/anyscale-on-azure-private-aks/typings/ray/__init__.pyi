# Minimal Ray stub for editor type checking.
# The proof scripts run in environments where Ray is installed, but this
# repository doesn't vendor Ray as a local development dependency.

from typing import Any, Callable, Generic, Sequence, TypeVar, overload

_R = TypeVar("_R")
_T = TypeVar("_T")


class ObjectRef(Generic[_T]): ...


class RemoteFunction(Generic[_R]):
    def remote(self, *args: Any, **kwargs: Any) -> ObjectRef[_R]: ...


@overload
def remote(__function: Callable[..., _R], /) -> RemoteFunction[_R]: ...
@overload
def remote(
    __function: None = ...,
    /,
    *,
    num_cpus: int | float | None = ...,
    num_gpus: int | float | None = ...,
    **options: Any,
) -> Callable[[Callable[..., _R]], RemoteFunction[_R]]: ...


def init(
    *,
    address: str | None = ...,
    ignore_reinit_error: bool = ...,
    **options: Any,
) -> None: ...


@overload
def get(object_ref: ObjectRef[_T], /, *, timeout: float | None = ...) -> _T: ...
@overload
def get(object_refs: Sequence[ObjectRef[_T]], /, *, timeout: float | None = ...) -> list[_T]: ...


def cluster_resources() -> dict[str, float]: ...
def shutdown() -> None: ...
