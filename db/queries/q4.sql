-- Every sample, its sex, and how many runs used it
SELECT s.sample_id,
       s.sex,
       (SELECT COUNT(*) FROM run_samples rs WHERE rs.sample_id = s.sample_id) AS n_runs
FROM samples s
ORDER BY s.sample_id;
