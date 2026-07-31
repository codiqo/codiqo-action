# Starter workflow (optional discovery layer)

These two files make Codiqo appear under **Actions → New workflow** for repositories in the
`codiqo` org (and can be submitted to [actions/starter-workflows](https://github.com/actions/starter-workflows)
for global discovery).

To enable org-wide suggestions, copy both files into the `codiqo/.github` repository:

```
codiqo/.github/
└── workflow-templates/
    ├── codiqo.yml
    └── codiqo.properties.json
```

`filePatterns: ["pom\\.xml$"]` scopes the suggestion to Maven repositories. This is separate
from the Marketplace listing (which comes from `action.yml` at the repo root).

Note: `codiqo.yml` currently references `codiqo/codiqo-action@main`, because no release exists yet.
Change it to a tagged ref before submitting to `actions/starter-workflows` — handing strangers a
template that tracks a moving branch is not a kindness.
