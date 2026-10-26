# Starter workflow (optional discovery layer)

These two files make Codiqo appear under **Actions → New workflow** for every repository in an
organization whose `.github` repository carries them. That is the quickest way for a team adopting
Codiqo to roll it out: each repository then adds the workflow in two clicks instead of a copy-paste.
They can also be submitted to [actions/starter-workflows](https://github.com/actions/starter-workflows)
for global discovery.

To enable it for an organization, copy both files into that organization's `.github` repository:

```
<your-org>/.github/
└── workflow-templates/
    ├── codiqo.yml
    └── codiqo.properties.json
```

`filePatterns: ["pom\\.xml$"]` scopes the suggestion to Maven repositories. `$default-branch` in
`codiqo.yml` is filled in by GitHub when a repository adds the workflow; if you copy the file by hand
instead, replace it with the branch name. This is separate from the Marketplace listing (which comes
from `action.yml` at the repo root).

Note: `codiqo.yml` currently references `codiqo/codiqo-action@main`, because no release exists yet.
Change it to a tagged ref before submitting to `actions/starter-workflows` — handing strangers a
template that tracks a moving branch is not a kindness.
