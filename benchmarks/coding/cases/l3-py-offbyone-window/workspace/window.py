def max_in_windows(nums, k):
    """Return the maximum of each contiguous window of size k.

    For nums=[1,3,-1,-3,5,3,6,7], k=3 the windows are
    [1,3,-1]->3, [3,-1,-3]->3, [-1,-3,5]->5, [-3,5,3]->5,
    [5,3,6]->6, [3,6,7]->7  => [3,3,5,5,6,7].
    """
    out = []
    for i in range(len(nums) - k):
        window = nums[i:i + k]
        out.append(max(window))
    return out
