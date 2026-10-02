// @ts-check
import eslint from '@eslint/js';
import nodePlugin from 'eslint-plugin-n';
import perfectionist from 'eslint-plugin-perfectionist';
import promisePlugin from 'eslint-plugin-promise';
import regexpPlugin from 'eslint-plugin-regexp';
import sonarjs from 'eslint-plugin-sonarjs';
import unicorn from 'eslint-plugin-unicorn';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  // Global ignores
  {
    ignores: ['**/node_modules/**', '.bats/**', 'eslint.config.mjs'],
  },

  // Base JavaScript and TypeScript strict configuration
  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,

  // Core configuration for all TypeScript files. Everything here runs on Node: the pi extension,
  // its unit tests, and the e2e driver.
  {
    files: ['**/*.ts'],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
      n: nodePlugin,
      perfectionist,
      promise: promisePlugin,
      regexp: regexpPlugin,
      sonarjs,
      unicorn,
    },
    rules: {
      // TypeScript-ESLint strict rules
      '@typescript-eslint/explicit-function-return-type': [
        'error',
        {
          allowExpressions: true,
          allowTypedFunctionExpressions: true,
          allowHigherOrderFunctions: true,
        },
      ],
      '@typescript-eslint/explicit-module-boundary-types': 'error',
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
        },
      ],
      '@typescript-eslint/naming-convention': [
        'error',
        {
          selector: 'default',
          format: ['camelCase'],
          leadingUnderscore: 'allow',
          trailingUnderscore: 'forbid',
        },
        {
          selector: 'variable',
          format: ['camelCase', 'UPPER_CASE'],
          leadingUnderscore: 'allow',
        },
        {
          selector: 'typeLike',
          format: ['PascalCase'],
        },
        {
          selector: 'enumMember',
          format: ['PascalCase', 'UPPER_CASE'],
        },
        {
          selector: 'property',
          format: null, // Allow any format for object properties
        },
        {
          selector: 'objectLiteralProperty',
          format: null,
        },
      ],
      '@typescript-eslint/consistent-type-exports': 'error',
      '@typescript-eslint/consistent-type-imports': [
        'error',
        {
          prefer: 'type-imports',
          fixStyle: 'inline-type-imports',
        },
      ],

      // Unicorn recommended rules
      ...unicorn.configs.recommended.rules,
      'unicorn/name-replacements': [
        'error',
        {
          allowList: {
            args: true,
            ctx: true,
            dir: true,
            env: true,
            err: true,
            fn: true,
            params: true,
          },
        },
      ],
      'unicorn/no-null': 'off', // child_process reports a signal exit as a null code
      'unicorn/filename-case': [
        'error',
        {
          case: 'kebabCase',
        },
      ],

      // SonarJS recommended rules
      ...sonarjs.configs.recommended.rules,

      // Perfectionist sorting rules
      'perfectionist/sort-imports': [
        'error',
        {
          type: 'natural',
          order: 'asc',
          groups: ['builtin', 'external', 'internal', ['parent', 'sibling', 'index'], 'type', 'unknown'],
          newlinesBetween: 0,
        },
      ],
      'perfectionist/sort-named-imports': [
        'error',
        {
          type: 'natural',
          order: 'asc',
        },
      ],
      'perfectionist/sort-exports': [
        'error',
        {
          type: 'natural',
          order: 'asc',
        },
      ],
      'perfectionist/sort-interfaces': [
        'error',
        {
          type: 'natural',
          order: 'asc',
        },
      ],
      'perfectionist/sort-object-types': [
        'error',
        {
          type: 'natural',
          order: 'asc',
        },
      ],
      'perfectionist/sort-objects': [
        'error',
        {
          type: 'natural',
          order: 'asc',
          partitionByComment: true,
        },
      ],
      'perfectionist/sort-enums': [
        'error',
        {
          type: 'natural',
          order: 'asc',
        },
      ],

      // Promise plugin rules
      ...promisePlugin.configs.recommended.rules,
      'promise/always-return': 'error',
      'promise/no-return-wrap': 'error',
      'promise/param-names': 'error',
      'promise/catch-or-return': 'error',
      'promise/no-new-statics': 'error',

      // Regexp plugin rules
      ...regexpPlugin.configs.recommended.rules,

      // Node.js rules
      ...nodePlugin.configs['flat/recommended-module'].rules,
      'n/no-missing-import': 'off', // TypeScript resolves imports, including the .ts extensions

      // General strict rules
      'no-console': 'error',
      'no-debugger': 'error',
      'prefer-const': 'error',
      'no-var': 'error',
      eqeqeq: ['error', 'always'],
      curly: ['error', 'all'],
    },
  },

  // Test files and fixtures
  {
    files: ['plugin-tests/**/*.ts'],
    rules: {
      '@typescript-eslint/no-floating-promises': [
        'error',
        {
          allowForKnownSafeCalls: [{ from: 'package', name: ['test', 'describe', 'it', 'suite'], package: 'node:test' }],
        },
      ],
      '@typescript-eslint/no-non-null-assertion': 'off',
      'n/no-unpublished-import': 'off', // Tests and fixtures import devDependencies
      'sonarjs/no-duplicate-string': 'off',
      'unicorn/import-style': 'off', // Allow namespace imports for Node.js built-ins
    },
  },
);
