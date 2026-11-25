<script setup lang="ts">
// At the foot of every page: where this panel's source lives (AGPL), and what
// it is built on.
const REPO = 'https://github.com/The1UNeed/roomkey-public'
const UPSTREAM = 'https://github.com/jinqians/proxy-stack'
</script>

<template>
  <footer class="footer" data-test="footer">
    <a :href="REPO" target="_blank" rel="noopener noreferrer" data-test="source">roomkey</a> ·
    built on <a :href="UPSTREAM" target="_blank" rel="noopener noreferrer" data-test="powered-by">PSM</a>
  </footer>
</template>
