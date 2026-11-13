-- Which runs included NA12878, and as what?
SELECT run_id, condition
FROM run_samples
WHERE sample_id = 'NA12878';
