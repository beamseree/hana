# Isolated prototypes

The throwaway native window/focus experiment is published on the [prototype/window-focus branch](https://github.com/beamseree/hana-searchbar/tree/prototype/window-focus/prototypes/window-focus). Its original local Git history is preserved in that branch's ancestry. Main holds project decisions and tracker configuration; no production app scaffold has been created.

- [Run instructions](https://github.com/beamseree/hana-searchbar/blob/prototype/window-focus/prototypes/window-focus/README.md)
- [Test matrix](https://github.com/beamseree/hana-searchbar/blob/prototype/window-focus/prototypes/window-focus/TEST-MATRIX.md)
- [Minimize investigation](https://github.com/beamseree/hana-searchbar/blob/prototype/window-focus/prototypes/window-focus/debug/MINIMIZE-INVESTIGATION.md)

On Beam's original checkout, the independent repository remains at `prototypes/window-focus` and is ignored by the parent repository. Its build and local history are untouched.

For another checkout, clone the prototype branch separately:

```sh
git clone --branch prototype/window-focus https://github.com/beamseree/hana-searchbar.git hana-window-prototype
cd hana-window-prototype
./prototypes/window-focus/run.sh
```

Use a separate clone rather than switching the original parent checkout to the prototype branch, which would collide with its existing nested repository.
