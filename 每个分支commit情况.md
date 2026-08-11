## swapq-v2-base
94f9b3980dd (HEAD -> swapq-v2-base) mm/page_reporting: Add page_reporting_delay_ms module parameter
1843a6ac66c hugetlb: only adjust reservation during unmapping if mapcount is 0
7451c4b0d1b mm: use proper PTE accessor in move_ptes()
65c91b55763 memcg: bypass the reclaim and oom killer for dying tasks once oom_reaper is done
3af57bc5795 mm/page_alloc: boost watermarks on atomic allocation failure
eab53018f9e Documentation: zram: correct algo parameters configuration documentation
4478143d356 mm: memcg: stop reclaim when a limit update is superseded
869d125c2ee zram: validate deflate params
29a00fb5f39 zram: set default primary compressor in zram_destroy_comps()
3b334ec8521 mm/hugetlb_cma: support percentage-based hugetlb_cma reservation
8ad1862ef1f mm/vmscan: reduce lru_lock contention via vmstat-derived scan-balance cost
e0b79251778 mm/vmstat, mm/memcontrol: add _monotonic vmstat readers
48a93dc7c74 mm: vmscan: fix node reclaim ignoring swappiness parameter
ae72a02a6bf memcg: move mem_cgroup_swappiness and vm_swappiness to mm/swap.h
a20c72f56f7 selftests/mm: transhuge-stress: check duration inside page loop
524086e9ec3 mm: mglru: promote mapped executable folios after first usage
a74065608c3 mm: vmscan: add a helper to identify file-backed executable folios
28b1a440096 mm: vmscan: convert folio_referenced() to use vma_flags_t
64bce437d2c mm/kmemleak: report RCU-tasks quiescent states during the scan
c8ae1e36230 tools/testing/selftests/mm: add MAP_PRIVATE-/dev/zero merge tests
7a074276405 tools/testing/vma: add test to assert MAP_PRIVATE-/dev/zero is anon
cc3b846182d mm/vma: make MAP_PRIVATE-mapped /dev/zero mappings truly anonymous
bfa91689531 mm/vma: only permit MAP_PRIVATE /dev/zero to be mapped anonymous
2a946dd1ba3 tools/testing/selftests/mm: test virtual page offset merge behaviour
73976bc548f tools/testing/vma: expand VMA merge tests to assert virt pgoff
2315b49a34a mm/rmap: use virt pgoff for MAP_PRIVATE file-backed anon folios
4f6c9bed5a8 mm: introduce and use linear_folio_page_index()
856ea5eb947 mm/rmap: track whether the page VMA mapped walk is anonymous
15ba139733e mm: propagate VMA virtual page offset on map, remap, split + merge
b0908747fab mm: introduce and use vma_filebacked_address()
2a0bfe9eb62 mm: update print_bad_page_map() to show virtual page index
9a47084fb23 mm: abstract vma_address() and introduce vma_anon_address()
5c27695289e mm: introduce linear_virt_page_index()
509ecebf0f8 mm/vma: introduce VMA virtual page offset field and add helpers
42b5d0092a8 mm/swap: fix swap_cluster_lock() !CONFIG_SWAP stub signature mismatch
012dbe5345c mm/kconfig: drop redundant dependency wrappers
fb26be02c64 mm/vmstat: add NRSWP{IN,OUT} counters
27b8c0293d6 mm/swap: remove SWP_FS_OPS
f338485f5cd mm/swap: use swap_ops to register swap device's methods
bcf0735fcaa mm/swap: remove count_swpout_vm_event
d13f4e2a221 mm/swap: also use struct swap_iocb for block I/O
042a0bc3802 mm/swap: introduce struct swap_io_ctx
3e0f6c8aa8b shmem: provide a shmem_write_folio wrapper
eccc21b87ec mm: standardize printing for pgtable entries


## swapq-v2 
aa162bca0b4 (HEAD -> swapq-v2) lib/plist.c: remove requeue function
855444d4343 mm/swap: drop swap active plist
d572da6fba3 mm/swap: bound synchronous discard during allocation
67c9e1f71a8 mm/swap: remove available list
687a093f2f9 mm/swap: add priority queue for swap device allocation
18b427c256e mm/swap: change back to use each swap device's percpu cluster
a1f009ca017 mm/swap: consolidate swap inuse accounting helpers
c3b048b49b5 mm/swap: remove swapon mutex and update proc reader
7bdb0a7c2a6 mm/swap: change the swapon lock into a percpu rwsem
ac0f7e83994 mm/swap: introduce swap device iteration helper
31462795580 mm/swap: cleanup and document swap device availability flag usage
ba0747191be mm/swap: slightly cleanup the code for hibernation error handling
51a024e206b mm/swap: remove unused parameter for reading swap header
94f9b3980dd (swapq-v2-base) mm/page_reporting: Add page_reporting_delay_ms module parameter

## swapq-v1-before
bdc38bfc126 (HEAD -> swapq-v1-before) mm/damon/core: handle unreset probe_hits in probe_hits_mvsum()
ea330303246 mm/damon/core: update probe hits for new parameter commit
3e7bdf53d96 mm/damon/core: s/nr_accesses_for_new_attrs/nr_samples_for_new_attrs/
e8cd6d8b1c3 mm/damon/core: s/nr_accesses_to_accesses_bp/sample_count_to_bp/
4aca5b35573 mm/damon/core: s/accesses_bp_to_nr_accesses/sample_bp_to_count/
38aae74ef69 mm/damon/core: s/damon_max_nr_accesses()/damon_nr_samples_per_aggr()/
6789a149adf mm/damon/core: remove comment and test for nr_to_bp() divide-by-zero
31cf305afda mm/bootmem_info: remove CONFIG_HAVE_BOOTMEM_INFO_NODE
39e132d984e mm/sparse: remove bootmem_info.h include
8881d76f726 mm/hugetlb_vmemmap: remove bootmem_info leftovers
b64d1d7f4ed x86/mm: remove CONFIG_HAVE_BOOTMEM_INFO_NODE
51a8bdfc0d3 x86/mm: stop marking page tables as MIX_SECTION_INFO
cfaa87a4577 x86/mm: stop marking vmemmap as SECTION_INFO
0f9064e3d96 mm/bootmem_info: allow calling free_bootmem_page() on pages without a bootmem_type
42128b37fd1 s390/mm: use free_reserved_pages() in vmem_free_pages()
a3fe1b83430 mm: provide free_reserved_pages(), removing x86 variant
511e0b95fe1 x86/mm: drop order parameter from free_pagetable()
ee974b7050d kselftest: alloc_tag: extend the allocinfo ioctl kselftest
5d6269324cd kselftest: alloc_tag: add kselftest for ioctl interface
5318a6f7e0f alloc_tag: add accuracy based filtering to ioctl
18de5706a3f alloc_tag: add size-based filtering to ioctl
ea1202126ad alloc_tag: add ioctl filters to /proc/allocinfo
1d7056a9426 alloc_tag-add-ioctl-to-proc-allocinfo-fix
8df02872f6b alloc_tag: add ioctl to /proc/allocinfo
dca8c52bd1f mm: nommu: fix the error path when vma_iter_prealloc() fails
75a84ebb13d Documentation/userfaultfd: document RWP working set tracking
3329cf3e52a selftests/mm: add userfaultfd RWP tests
80acf771c82 userfaultfd: add UFFDIO_SET_MODE for runtime sync/async toggle
d075017a559 userfaultfd: add UFFD_FEATURE_RWP_ASYNC for async fault resolution
dbc7d8f0bf9 mm/pagemap: add PAGE_IS_ACCESSED for RWP tracking
8ce1bc73e6d mm/userfaultfd: add RWP fault delivery and expose UFFDIO_REGISTER_MODE_RWP
f73ddb37c28 userfaultfd: add UFFDIO_REGISTER_MODE_RWP and UFFDIO_RWPROTECT plumbing
45b74279f67 mm: handle VM_UFFD_RWP in khugepaged, rmap, and GUP
5e6b5ae96f1 mm: preserve RWP marker across PTE rewrites
ec191bd9063 mm: add MM_CP_UFFD_RWP change_protection() flag
1246e8d5de1 mm: add VM_UFFD_RWP VMA flag
1c7c5e703eb userfaultfd: test uffd VMA flags through the vma_flags_t API
30c83145c5b mm: rename uffd-wp PTE accessors to uffd
abc897da912 mm: rename uffd-wp PTE bit macros to uffd
89c6b5ecb4b mm: decouple protnone helpers from CONFIG_NUMA_BALANCING
3f00cd2e6c3 mm/shmem: annotate benign data-race in shmem_getattr()
7d9450c83c2 mm: move reclaim-internal declarations out of swap.h
9a32a1f9d0e mm: rename swap.c to folio.c


## swapq-v1-patch8
[root@localhost mm]# git log --oneline
5d5c0f6c4e6 (HEAD -> swapq-v1-patch8) mm/swap: change back to use each swap device's percpu cluster
882d0a5cd92 mm/swap: consolidate swap inuse accounting helpers
3a3d24242f8 mm/swap: remove swapon mutex and update proc reader
51040a30010 mm/swap: change the swapon lock into a percpu rwsem
54cf4283aa9 mm/swap: introduce swap device iteration helper
5cf7c5be6c0 mm/swap: cleanup and document swap device availability flag usage
ccae1c03c38 mm/swap: slightly cleanup the code for hibernation error handling
714437377fb mm/swap: remove unused parameter for reading swap header
bdc38bfc126 (swapq-v1-before) mm/damon/core: handle unreset probe_hits in probe_hits_mvsum()
ea330303246 mm/damon/core: update probe hits for new parameter commit
3e7bdf53d96 mm/damon/core: s/nr_accesses_for_new_attrs/nr_samples_for_new_attrs/
e8cd6d8b1c3 mm/damon/core: s/nr_accesses_to_accesses_bp/sample_count_to_bp/
4aca5b35573 mm/damon/core: s/accesses_bp_to_nr_accesses/sample_bp_to_count/
38aae74ef69 mm/damon/core: s/damon_max_nr_accesses()/damon_nr_samples_per_aggr()/
6789a149adf mm/damon/core: remove comment and test for nr_to_bp() divide-by-zero


## swapq-v1-patch13
9854da38189 (HEAD -> swapq-v1-patch13) lib/plist.c: remove requeue function
fb02ba7b045 mm/swap: drop swap active plist
b07fd43d210 mm/swap: perform sync discard on single device more proactively
5a55ad9298e mm/swap: remove available list
aea1fafe81e mm/swap: add priority queue for swap device allocation
5d5c0f6c4e6 (swapq-v1-patch8) mm/swap: change back to use each swap device's percpu cluster
882d0a5cd92 mm/swap: consolidate swap inuse accounting helpers
3a3d24242f8 mm/swap: remove swapon mutex and update proc reader
51040a30010 mm/swap: change the swapon lock into a percpu rwsem
54cf4283aa9 mm/swap: introduce swap device iteration helper
5cf7c5be6c0 mm/swap: cleanup and document swap device availability flag usage
ccae1c03c38 mm/swap: slightly cleanup the code for hibernation error handling
714437377fb mm/swap: remove unused parameter for reading swap header
bdc38bfc126 (swapq-v1-before) mm/damon/core: handle unreset probe_hits in probe_hits_mvsum()
ea330303246 mm/damon/core: update probe hits for new parameter commit
3e7bdf53d96 mm/damon/core: s/nr_accesses_for_new_attrs/nr_samples_for_new_attrs/
e8cd6d8b1c3 mm/damon/core: s/nr_accesses_to_accesses_bp/sample_count_to_bp/
4aca5b35573 mm/damon/core: s/accesses_bp_to_nr_accesses/sample_bp_to_count/
38aae74ef69 mm/damon/core: s/damon_max_nr_accesses()/damon_nr_samples_per_aggr()/
6789a149adf mm/damon/core: remove comment and test for nr_to_bp() divide-by-zero
31cf305afda mm/bootmem_info: remove CONFIG_HAVE_BOOTMEM_INFO_NODE


